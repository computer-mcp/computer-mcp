enum OAuthSchema {
  static let statements = [
    #"CREATE TABLE oauthAuthorizationRequests (id TEXT PRIMARY KEY, tunnelID TEXT NOT NULL, pairingCode TEXT NOT NULL, statusDigest TEXT NOT NULL UNIQUE, expiresAt DOUBLE NOT NULL, payloadJSON TEXT NOT NULL, UNIQUE(tunnelID, pairingCode))"#,
    #"CREATE TABLE oauthGrants (id TEXT PRIMARY KEY, tunnelID TEXT NOT NULL, payloadJSON TEXT NOT NULL)"#,
    #"CREATE TABLE oauthAuthorizationCodes (digest TEXT PRIMARY KEY, grantID TEXT NOT NULL REFERENCES oauthGrants(id), expiresAt DOUBLE NOT NULL, payloadJSON TEXT NOT NULL)"#,
    #"CREATE TABLE oauthTokens (digest TEXT PRIMARY KEY, grantID TEXT NOT NULL REFERENCES oauthGrants(id), kind TEXT NOT NULL, expiresAt DOUBLE NOT NULL, payloadJSON TEXT NOT NULL)"#,
    #"CREATE INDEX oauthAuthorizationRequests_on_tunnelID ON oauthAuthorizationRequests(tunnelID)"#,
    #"CREATE INDEX oauthGrants_on_tunnelID ON oauthGrants(tunnelID)"#,
    #"CREATE INDEX oauthTokens_on_grantID ON oauthTokens(grantID)"#,
    #"CREATE INDEX oauthTokens_on_expiry ON oauthTokens(kind, expiresAt)"#,
  ]
}
