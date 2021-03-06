//
//  Database.swift
//  MongoSwift
//
//  Created by Joannis Orlandos on 27/01/16.
//  Copyright © 2016 PlanTeam. All rights reserved.
//

import Foundation
import BSON

/// A Mongo Database. Cannot be publically initialized. But you can get a database object by subscripting a Server with a String
public class Database {
    /// The server that this Database is a part of
    public let server: Server
    
    /// The database's name
    public let name: String
    
    public internal(set) var authenticated = true
    
    internal init(server: Server, databaseName name: String) {
        let name = name.stringByReplacingOccurrencesOfString(".", withString: "")
        
        self.server = server
        self.name = name
    }
    
    /// This subscript is used to get a collection by providing a name as a String
    public subscript (collection: String) -> Collection {
        return Collection(database: self, collectionName: collection)
    }
    
    @warn_unused_result
    internal func documentsInMessage(message: Message) throws -> [Document] {
        guard case .Reply(_, _, _, _, _, _, let documents) = message else {
            throw InternalMongoError.IncorrectReply(reply: message)
        }
        
        return documents
    }
    
    @warn_unused_result
    internal func firstDocumentInMessage(message: Message) throws -> Document {
        let documents = try documentsInMessage(message)
        
        guard let document = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: message)
        }
        
        return document
    }
    
    /// Executes a command on this database using a query message
    @warn_unused_result
    internal func executeCommand(command: Document) throws -> Message {
        let cmd = self["$cmd"]
        let commandMessage = Message.Query(requestID: server.getNextMessageID(), flags: [], collection: cmd, numbersToSkip: 0, numbersToReturn: 1, query: command, returnFields: nil)
        let id = try server.sendMessage(commandMessage)
        return try server.awaitResponse(id)
    }
    
    @warn_unused_result
    public func getCollectionInfos(filter filter: Document? = nil) throws -> Cursor<Document> {
        var request: Document = ["listCollections": 1]
        if let filter = filter {
            request["filter"] = filter
        }
        
        let reply = try executeCommand(request)
        
        let result = try firstDocumentInMessage(reply)
        
        guard let code = result["ok"]?.intValue, cursor = result["cursor"] as? Document where code == 1 else {
            throw MongoError.CommandFailure
        }
        
        return try Cursor(cursorDocument: cursor, server: server, chunkSize: 10, transform: { $0 })
    }
    
    /// Gets the collections in this database
    @warn_unused_result
    public func getCollections(filter filter: Document? = nil) throws -> Cursor<Collection> {
        let infoCursor = try self.getCollectionInfos(filter: filter)
        return Cursor(base: infoCursor) { collectionInfo in
            guard let name = collectionInfo["name"]?.stringValue else { return nil }
            return self[name]
        }
    }
    
    @warn_unused_result
    internal func isMaster() throws -> Document {
        let response = try self.executeCommand(["ismaster": Int32(1)])
        
        return try firstDocumentInMessage(response)
    }
}

extension Database {
    /// Generates a random String
    private func generateNonce() -> String {
        let allowedCharacters = "!\"#'$%&()*+-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_$"
        
        var randomString = ""
        
        for _ in 0..<24 {
            let randomNumber: Int
            
            #if os(Linux)
                randomNumber = Int(random() % allowedCharacters.characters.count)
            #else
                randomNumber = Int(arc4random_uniform(UInt32(allowedCharacters.characters.count)))
            #endif
            
            let letter = allowedCharacters[allowedCharacters.startIndex.advancedBy(randomNumber)]
            
            randomString.append(letter)
        }
        
        return randomString
    }
    
    /// Parses a SCRAM response
    private func parseResponse(response: String) -> [String: String] {
        var parsedResponse = [String: String]()
        
        for part in response.characters.split(",") where String(part).characters.count >= 3 {
            let part = String(part)
            
            if let first = part.characters.first {
                parsedResponse[String(first)] = part[part.startIndex.advancedBy(2)..<part.endIndex]
            }
        }
        
        return parsedResponse
    }
    
    /// Used for applying SHA1_HMAC on a password and salt
    private func digest(password: String, data: [UInt8]) throws -> [UInt8] {
        var passwordBytes = [UInt8]()
        passwordBytes.appendContentsOf(password.utf8)
        
        return try Authenticator.HMAC(key: passwordBytes, variant: .sha1).authenticate(data)
    }
    
    /// xor's two arrays of bytes
    private func xor(left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        let loops = min(left.count, right.count)
        
        result.reserveCapacity(loops)
        
        for i in 0..<loops {
            result.append(left[i] ^ right[i])
        }
        
        return result
    }
    
    /// Applies the `hi` (PBKDF2 with HMAC as PseudoRandom Function)
    private func hi(password: String, salt: [UInt8], iterations: Int) throws -> [UInt8] {
        var salt = salt
        salt.appendContentsOf([0, 0, 0, 1])
        
        var ui = try digest(password, data: salt)
        var u1 = ui
        
        for _ in 0..<iterations - 1 {
            u1 = try digest(password, data: u1)
            ui = xor(ui, u1)
        }
        
        return ui
    }
    
    /// Last step(s) in the SASL process
    /// TODO: Set a timeout for connecting
    private func completeSASLAuthentication(payload: String, signature: [UInt8], response: Document) throws {
        // If we failed authentication
        guard response["ok"]?.int32Value == 1 else {
            throw MongoAuthenticationError.IncorrectCredentials
        }
        
        // If we're done
        if response["done"]?.boolValue == true {
            return
        }
        
        guard let stringResponse = response["payload"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let conversationId = response["conversationId"] else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let finalResponse = String(bytes: [UInt8](base64: stringResponse), encoding: NSUTF8StringEncoding) else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        let dictionaryResponse = self.parseResponse(finalResponse)
        
        guard let v = dictionaryResponse["v"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        let serverSignature = [UInt8](base64: v)
        
        guard serverSignature == signature else {
            throw MongoAuthenticationError.ServerSignatureInvalid
        }
        
        let response = try self.executeCommand([
                                                   "saslContinue": Int32(1),
                                                   "conversationId": conversationId,
                                                   "payload": ""
            ])
        
        guard case .Reply(_, _, _, _, _, _, let documents) = response, let responseDocument = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: response)
        }
        
        try self.completeSASLAuthentication(payload, signature: serverSignature, response: responseDocument)
    }
    
    /// Respond to a challenge
    /// TODO: Set a timeout for connecting
    private func challenge(details: (username: String, password: String), continuation: (nonce: String, response: Document)) throws {
        // If we failed the authentication
        guard continuation.response["ok"]?.int32Value == 1 else {
            throw MongoAuthenticationError.IncorrectCredentials
        }
        
        // If we're done
        if continuation.response["done"]?.boolValue == true {
            return
        }
        
        // Get our ConversationID
        guard let conversationId = continuation.response["conversationId"] else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Create our header
        var basicHeader = [UInt8]()
        basicHeader.appendContentsOf("n,,".utf8)
        
        guard let header = basicHeader.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Decode the challenge
        guard let stringResponse = continuation.response["payload"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let decodedStringResponse = String(bytes: [UInt8](base64: stringResponse), encoding: NSUTF8StringEncoding) else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Parse the challenge
        let dictionaryResponse = self.parseResponse(decodedStringResponse)
        
        guard let nonce = dictionaryResponse["r"], let stringSalt = dictionaryResponse["s"], let stringIterations = dictionaryResponse["i"], let iterations = Int(stringIterations) where String(nonce[nonce.startIndex..<nonce.startIndex.advancedBy(24)]) == continuation.nonce else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Build up the basic information
        let noProof = "c=\(header),r=\(nonce)"
        
        // Calculate the proof
        var digestBytes = [UInt8]()
        digestBytes.appendContentsOf("\(details.username):mongo:\(details.password)".utf8)
        
        let digest = digestBytes.md5().toHexString()
        let salt = [UInt8](base64: stringSalt)
        
        let saltedPassword = try hi(digest, salt: salt, iterations: iterations)
        var ck = [UInt8]()
        ck.appendContentsOf("Client Key".utf8)
        
        var sk = [UInt8]()
        sk.appendContentsOf("Server Key".utf8)
        
        let clientKey = try Authenticator.HMAC(key: saltedPassword, variant: .sha1).authenticate(ck)
        let storedKey = clientKey.sha1()
        
        let fixedUsername = details.username.stringByReplacingOccurrencesOfString("=", withString: "=3D").stringByReplacingOccurrencesOfString(",", withString: "=2C")
        
        let authenticationMessage = "n=\(fixedUsername),r=\(continuation.nonce),\(decodedStringResponse),\(noProof)"
        
        var authenticationMessageBytes = [UInt8]()
        authenticationMessageBytes.appendContentsOf(authenticationMessage.utf8)
        
        let clientSignature = try Authenticator.HMAC(key: storedKey, variant: .sha1).authenticate(authenticationMessageBytes)
        let clientProof = xor(clientKey, clientSignature)
        let serverKey = try Authenticator.HMAC(key: saltedPassword, variant: .sha1).authenticate(sk)
        let serverSignature = try Authenticator.HMAC(key: serverKey, variant: .sha1).authenticate(authenticationMessageBytes)
        
        // Base64 the proof
        guard let proof = clientProof.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Base64 the payload
        guard let payload = "\(noProof),p=\(proof)".cStringBsonData.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Send the proof
        let response = try self.executeCommand([
                                                   "saslContinue": Int32(1),
                                                   "conversationId": conversationId,
                                                   "payload": payload
            ])
        
        // If we don't get a correct reply
        guard case .Reply(_, _, _, _, _, _, let documents) = response, let responseDocument = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: response)
        }
        
        // Complete Authentication
        try self.completeSASLAuthentication(payload, signature: serverSignature, response: responseDocument)
    }
    
    /// Authenticates to this database using SASL
    /// TODO: Support authentication DBs
    /// TODO: Set a timeout for connecting
    internal func authenticateSASL(details: (username: String, password: String)) throws {
        let nonce = generateNonce()
        
        let fixedUsername = details.username.stringByReplacingOccurrencesOfString("=", withString: "=3D").stringByReplacingOccurrencesOfString(",", withString: "=2C")
        
        guard let payload = "n,,n=\(fixedUsername),r=\(nonce)".cStringBsonData.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        let response = try self.executeCommand([
                                                   "saslStart": Int32(1),
                                                   "mechanism": "SCRAM-SHA-1",
                                                   "payload": payload
            ])
        
        let responseDocument = try firstDocumentInMessage(response)
        
        try self.challenge(details, continuation: (nonce: nonce, response: responseDocument))
    }
    
    /// Authenticate with MongoDB Challenge Response
    /// TODO: Set a timeout for connecting
    internal func authenticateCR(details: (username: String, password: String)) throws {
        // Get the server's nonce
        let response = try self.executeCommand([
                                                   "getNonce": Int32(1)
            ])
        
        // Get the server's challenge
        let document = try firstDocumentInMessage(response)
        
        guard let nonce = document["nonce"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Digest our password and prepare it for sending
        let digest = "\(details.username):mongo:\(details.password)".cStringBsonData.md5().toHexString()
        let key = "\(nonce)\(details.username)\(digest)".cStringBsonData.md5().toHexString()
        
        // Respond to the challengge
        let successResponse = try self.executeCommand([
                                                          "authenticate": 1,
                                                          "nonce": nonce,
                                                          "user": details.username,
                                                          "key": key
            ])
        
        let successDocument = try firstDocumentInMessage(successResponse)
        
        // Check for success
        guard let ok = successDocument["ok"]?.intValue where ok == 1 else {
            throw InternalMongoError.IncorrectReply(reply: successResponse)
        }
    }
}