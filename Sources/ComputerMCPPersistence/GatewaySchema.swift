/// The 0.1.0 database schema, created by one migration. Statements run in this order:
/// tables, then indexes; SQLite creates the implicit key indexes itself.
enum GatewaySchema {
  static let statements: [String] = [
    #"""
    CREATE TABLE "auditEvents" ("id" TEXT PRIMARY KEY, "occurredAt" DATETIME NOT NULL, "requestID" TEXT NOT NULL, "mcpRequestID" TEXT, "invocationID" TEXT, "parentRequestID" TEXT, "ticketID" TEXT, "caller" TEXT NOT NULL, "transport" TEXT, "socketConnectionID" TEXT, "tunnelInstanceID" TEXT, "tunnelProfileID" TEXT, "profileID" TEXT NOT NULL, "workspaceID" TEXT, "capabilityID" TEXT NOT NULL, "decision" TEXT NOT NULL, "errorCode" TEXT, "durationMilliseconds" INTEGER, "inputDigest" TEXT, "outputDigest" TEXT, "outputByteCount" INTEGER, "outputTruncated" BOOLEAN, "principalDigest" TEXT)
    """#,
    #"""
    CREATE TABLE "clientControlTrust" ("id" TEXT PRIMARY KEY, "principalID" TEXT NOT NULL, "profileID" TEXT NOT NULL, "caller" TEXT NOT NULL, "revision" INTEGER NOT NULL, "profile" TEXT NOT NULL, "fullAccessAllowed" BOOLEAN NOT NULL, "updatedAt" DATETIME NOT NULL, UNIQUE ("principalID", "profileID", "caller"))
    """#,
    #"""
    CREATE TABLE "configurationRevisions" ("id" TEXT PRIMARY KEY, "digest" TEXT NOT NULL, "manifest" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "activatedAt" DATETIME, "activationError" TEXT)
    """#,
    #"""
    CREATE TABLE "mcpExecutions" ("id" TEXT PRIMARY KEY, "metadataJSON" TEXT NOT NULL, "outputJSON" TEXT, "outputExpiresAt" DOUBLE)
    """#,
    #"""
    CREATE TABLE "operationTickets" ("id" TEXT PRIMARY KEY, "capabilityID" TEXT NOT NULL, "caller" TEXT NOT NULL, "profileID" TEXT NOT NULL, "principalID" TEXT NOT NULL, "workspaceID" TEXT, "inputDigest" TEXT NOT NULL, "stateDigest" TEXT, "state" TEXT NOT NULL, "prepareRequestID" TEXT NOT NULL, "invocationID" TEXT, "parentRequestID" TEXT, "createdAt" DATETIME NOT NULL, "expiresAt" DATETIME NOT NULL, "executingAt" DATETIME, "completedAt" DATETIME, "failureCode" TEXT, "authorizationRevision" INTEGER, "reviewSummary" TEXT, "controlSessionID" TEXT, "controlSessionRevision" INTEGER, "reviewTitle" TEXT)
    """#,
    #"""
    CREATE TABLE "pluginDerivedWorkspaces" ("workspaceID" TEXT PRIMARY KEY, "origin" TEXT NOT NULL, "sourceWorkspaceID" TEXT NOT NULL, "receiptID" TEXT NOT NULL, "payloadJSON" TEXT NOT NULL, UNIQUE ("origin", "sourceWorkspaceID", "receiptID"))
    """#,
    #"""
    CREATE TABLE "pluginOwnedDirectories" ("id" TEXT PRIMARY KEY, "payloadJSON" TEXT NOT NULL)
    """#,
    #"""
    CREATE TABLE "pluginState" ("id" INTEGER PRIMARY KEY, "revision" INTEGER NOT NULL, "payloadJSON" TEXT NOT NULL)
    """#,
    #"""
    CREATE TABLE "profiles" ("id" TEXT PRIMARY KEY, "capabilityIDsJSON" TEXT NOT NULL, "workspaceIDsJSON" TEXT NOT NULL, "allowedCallersJSON" TEXT NOT NULL, "fullShellEnabled" BOOLEAN NOT NULL, "updatedAt" DATETIME NOT NULL, "mcpServerIDsJSON" TEXT NOT NULL DEFAULT '[]', "mode" TEXT, "confirmationPolicy" TEXT, "authorizationRevision" INTEGER NOT NULL DEFAULT 0)
    """#,
    #"""
    CREATE TABLE "providerStates" ("id" TEXT PRIMARY KEY, "kind" TEXT NOT NULL, "executablePath" TEXT, "observedVersion" TEXT, "health" TEXT NOT NULL, "detail" TEXT, "checkedAt" DATETIME NOT NULL)
    """#,
    #"""
    CREATE TABLE "runtimeSettings" ("key" TEXT PRIMARY KEY, "value" TEXT NOT NULL, "updatedAt" DATETIME NOT NULL)
    """#,
    #"""
    CREATE TABLE "workspaceAliases" ("aliasWorkspaceID" TEXT PRIMARY KEY, "canonicalWorkspaceID" TEXT NOT NULL, "canonicalRootPath" TEXT NOT NULL, "migratedAt" DATETIME NOT NULL)
    """#,
    #"""
    CREATE TABLE "workspaceCanonicalRoots" ("canonicalRootPath" TEXT PRIMARY KEY, "workspaceID" TEXT NOT NULL, "createdAt" DATETIME NOT NULL)
    """#,
    #"""
    CREATE TABLE "workspaceDeduplicationReceipts" ("id" TEXT PRIMARY KEY, "planDigest" TEXT NOT NULL, "appliedAt" DATETIME NOT NULL, "payloadJSON" TEXT NOT NULL)
    """#,
    #"""
    CREATE TABLE "workspaces" ("id" TEXT PRIMARY KEY, "displayName" TEXT NOT NULL, "rootPath" TEXT NOT NULL, "bookmarkData" BLOB, "bookmarkIsStale" BOOLEAN NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL)
    """#,
    #"""
    CREATE INDEX "auditEvents_on_invocationID" ON "auditEvents"("invocationID")
    """#,
    #"""
    CREATE INDEX "auditEvents_on_mcpRequestID" ON "auditEvents"("mcpRequestID")
    """#,
    #"""
    CREATE INDEX "auditEvents_on_occurredAt" ON "auditEvents"("occurredAt")
    """#,
    #"""
    CREATE INDEX "auditEvents_on_socketConnectionID" ON "auditEvents"("socketConnectionID")
    """#,
    #"""
    CREATE INDEX "auditEvents_on_ticketID" ON "auditEvents"("ticketID")
    """#,
    #"""
    CREATE INDEX "auditEvents_on_tunnelInstanceID" ON "auditEvents"("tunnelInstanceID")
    """#,
    #"""
    CREATE INDEX "auditEvents_on_verified_scope" ON "auditEvents"("principalDigest", "profileID", "workspaceID", "occurredAt")
    """#,
    #"""
    CREATE INDEX "mcpExecutions_on_outputExpiresAt" ON "mcpExecutions"("outputExpiresAt")
    """#,
    #"""
    CREATE INDEX "workspaceAliases_on_canonicalWorkspaceID" ON "workspaceAliases"("canonicalWorkspaceID")
    """#,
    #"""
    CREATE INDEX "workspaceCanonicalRoots_on_workspaceID" ON "workspaceCanonicalRoots"("workspaceID")
    """#,
  ]
}
