import Foundation

package enum PluginManifestFixture {
  package static let platformExecutables =
    platformArtifacts + """

      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { platform_paths = { macos = 'helper' } }
      [[cli]]
      id = 'commands'
      executable = { platform_paths = { macos = 'helper' } }
      tree = { kind = 'helper', helper = { platform_paths = { macos = 'helper' } }, args = ['schema'] }
      """

  package static let platformArtifacts =
    header + """
      [compatibility]
      platforms = ['macos']
      [[compatibility.artifacts]]
      name = 'mac.zip'
      platforms = ['macos']
      architectures = ['arm64']
      [[compatibility.artifacts]]
      name = 'intel.zip'
      platforms = ['macos']
      architectures = ['x86_64']
      [[skills]]
      id = 'guide'
      path = 'skills'
      """

  package static let header =
    "id = 'test-package'\nname = 'Test package'\nversion = '1.2.3'\nplugin_api = 1\n"
  package static let combined =
    header + """
      [[dependencies]]
      id = 'vendor'
      commands = ['vendor-cli']
      instructions = 'Install the vendor CLI separately.'
      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { dependency = 'vendor' }
      args = ['mcp']
      [[cli]]
      id = 'commands'
      executable = { dependency = 'vendor' }
      tree = { kind = 'introspection', args = ['schema', '--json'] }
      [[skills]]
      id = 'guidance'
      path = 'skills'
      """
}
