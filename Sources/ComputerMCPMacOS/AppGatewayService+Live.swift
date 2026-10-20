import ComputerMCP

extension AppGatewayService {
  package static func live(
    controlPlane: AppControlPlaneService,
    directories: AppControlPlaneServiceDirectories
  ) -> AppGatewayService {
    AppGatewayService(
      controlPlane: controlPlane,
      socketConfiguration: GatewaySocketConfiguration(
        socketURL: directories.gatewaySocket,
        tunnelCredentialFile: directories.openAITunnelGatewayCredential
      )
    )
  }
}
