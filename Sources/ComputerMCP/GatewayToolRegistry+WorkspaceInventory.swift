import Foundation
import TOML

extension GatewayToolRegistry {
  internal static let workspaceManifestCandidates = [
    "Package.swift",
    "Package.resolved",
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lockb",
    "tsconfig.json",
    "vite.config.ts",
    "next.config.js",
    "pyproject.toml",
    "requirements.txt",
    "uv.lock",
    "poetry.lock",
    "Cargo.toml",
    "Cargo.lock",
    "go.mod",
    "go.sum",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "gradle.properties",
    "Gemfile",
    "Gemfile.lock",
    "composer.json",
    "composer.lock",
    "pubspec.yaml",
    "pubspec.lock",
    "Mix.exs",
    "mix.lock",
    "Project.toml",
    "Manifest.toml",
    "CMakeLists.txt",
    "Makefile",
    "Dockerfile",
    "docker-compose.yml",
    "compose.yml",
    ".gitignore",
    ".gitattributes",
    ".editorconfig",
    ".env.example",
    ".swift-format",
    ".swiftlint.yml",
    ".prettierrc",
    "eslint.config.js",
    ".github/workflows",
    "README.md",
    "README",
    "LICENSE",
  ]

  internal static let defaultTodoMarkers = ["TODO", "FIXME", "HACK", "XXX"]

  internal static let dependencyFileDescriptors: [WorkspaceDependencyFileDescriptor] = [
    WorkspaceDependencyFileDescriptor(name: "Package.swift", ecosystem: "swift", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "Package.resolved", ecosystem: "swift", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "package.json", ecosystem: "node", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "package-lock.json", ecosystem: "node", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "npm-shrinkwrap.json", ecosystem: "node", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "pnpm-lock.yaml", ecosystem: "node", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "yarn.lock", ecosystem: "node", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "bun.lock", ecosystem: "node", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "bun.lockb", ecosystem: "node", role: "lock"),
    WorkspaceDependencyFileDescriptor(
      name: "pyproject.toml", ecosystem: "python", role: "manifest"),
    WorkspaceDependencyFileDescriptor(
      name: "requirements.txt", ecosystem: "python", role: "requirements"),
    WorkspaceDependencyFileDescriptor(
      name: "requirements-dev.txt", ecosystem: "python", role: "requirements"),
    WorkspaceDependencyFileDescriptor(name: "poetry.lock", ecosystem: "python", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "uv.lock", ecosystem: "python", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "Pipfile", ecosystem: "python", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "Pipfile.lock", ecosystem: "python", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "setup.py", ecosystem: "python", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "setup.cfg", ecosystem: "python", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "Cargo.toml", ecosystem: "rust", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "Cargo.lock", ecosystem: "rust", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "go.mod", ecosystem: "go", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "go.sum", ecosystem: "go", role: "checksum"),
    WorkspaceDependencyFileDescriptor(name: "pom.xml", ecosystem: "jvm", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "build.gradle", ecosystem: "jvm", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "build.gradle.kts", ecosystem: "jvm", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "settings.gradle", ecosystem: "jvm", role: "manifest"),
    WorkspaceDependencyFileDescriptor(
      name: "settings.gradle.kts", ecosystem: "jvm", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "gradle.lockfile", ecosystem: "jvm", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "Gemfile", ecosystem: "ruby", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "Gemfile.lock", ecosystem: "ruby", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "composer.json", ecosystem: "php", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "composer.lock", ecosystem: "php", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "pubspec.yaml", ecosystem: "dart", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "pubspec.lock", ecosystem: "dart", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "Mix.exs", ecosystem: "elixir", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "mix.lock", ecosystem: "elixir", role: "lock"),
    WorkspaceDependencyFileDescriptor(name: "Project.toml", ecosystem: "julia", role: "manifest"),
    WorkspaceDependencyFileDescriptor(name: "Manifest.toml", ecosystem: "julia", role: "lock"),
  ]

  private static let documentationFileDescriptors: [String: WorkspaceDocumentationDescriptor] = [
    "agents.md": WorkspaceDocumentationDescriptor(
      category: "agent_instructions", source: "filename"),
    "readme": WorkspaceDocumentationDescriptor(category: "overview", source: "filename"),
    "contributing": WorkspaceDocumentationDescriptor(category: "contribution", source: "filename"),
    "code_of_conduct": WorkspaceDocumentationDescriptor(
      category: "code_of_conduct", source: "filename"),
    "security": WorkspaceDocumentationDescriptor(category: "security", source: "filename"),
    "support": WorkspaceDocumentationDescriptor(category: "support", source: "filename"),
    "changelog": WorkspaceDocumentationDescriptor(category: "changelog", source: "filename"),
    "changes": WorkspaceDocumentationDescriptor(category: "changelog", source: "filename"),
    "release_notes": WorkspaceDocumentationDescriptor(category: "changelog", source: "filename"),
    "license": WorkspaceDocumentationDescriptor(category: "license", source: "filename"),
    "licence": WorkspaceDocumentationDescriptor(category: "license", source: "filename"),
    "copying": WorkspaceDocumentationDescriptor(category: "license", source: "filename"),
    "notice": WorkspaceDocumentationDescriptor(category: "notice", source: "filename"),
  ]

  private static let agentFileDescriptors: [String: WorkspaceAgentFileDescriptor] = [
    "agents.md": WorkspaceAgentFileDescriptor(kind: "codex", source: "filename"),
    "claude.md": WorkspaceAgentFileDescriptor(kind: "claude", source: "filename"),
    "gemini.md": WorkspaceAgentFileDescriptor(kind: "gemini", source: "filename"),
    "copilot-instructions.md": WorkspaceAgentFileDescriptor(
      kind: "github_copilot", source: "filename"),
    ".cursorrules": WorkspaceAgentFileDescriptor(kind: "cursor", source: "filename"),
    ".windsurfrules": WorkspaceAgentFileDescriptor(kind: "windsurf", source: "filename"),
    "windsurf.md": WorkspaceAgentFileDescriptor(kind: "windsurf", source: "filename"),
  ]

  private static let scopedInstructionFilenames = [
    "AGENTS.md",
    "CLAUDE.md",
    "GEMINI.md",
    ".cursorrules",
    ".windsurfrules",
    "Windsurf.md",
  ]

  private static let scopedInstructionRuleDirectories = [
    ".cursor/rules",
    ".windsurf/rules",
  ]

  private static let agentFileScanSkippedDirectoryNames: Set<String> = [
    ".build",
    ".git",
    ".next",
    ".turbo",
    ".venv",
    "__pycache__",
    "build",
    "dist",
    "node_modules",
    "target",
    "venv",
  ]

  private static let testDirectoryNames: Set<String> = [
    "test",
    "tests",
    "__tests__",
    "spec",
    "specs",
    "e2e",
    "integration-test",
    "integration-tests",
    "integration_test",
    "integration_tests",
  ]

  private static let testFileExtensions: [String: String] = [
    "swift": "swift",
    "js": "javascript",
    "jsx": "javascript",
    "ts": "typescript",
    "tsx": "typescript",
    "mjs": "javascript",
    "cjs": "javascript",
    "py": "python",
    "rb": "ruby",
    "go": "go",
    "rs": "rust",
    "java": "java",
    "kt": "kotlin",
    "kts": "kotlin",
    "scala": "scala",
    "cs": "csharp",
    "php": "php",
    "dart": "dart",
    "ex": "elixir",
    "exs": "elixir",
    "erl": "erlang",
    "hrl": "erlang",
  ]

  private static let ciFileExtensions: Set<String> = ["yml", "yaml", "json", "toml"]

  private static let ciSkippedDirectoryNames: Set<String> = [
    ".git",
    ".hg",
    ".svn",
    ".build",
    ".cache",
    "node_modules",
    "DerivedData",
    "build",
    "dist",
  ]

  private static let configSkippedDirectoryNames: Set<String> = [
    ".git",
    ".hg",
    ".svn",
    ".build",
    ".cache",
    "node_modules",
    "DerivedData",
    "build",
    "dist",
  ]

  internal static let sourceSkippedDirectoryNames: Set<String> = [
    ".git",
    ".hg",
    ".svn",
    ".build",
    ".cache",
    ".swiftpm",
    "node_modules",
    "DerivedData",
    "build",
    "dist",
    "coverage",
    "vendor",
    ".venv",
    "venv",
    "__pycache__",
  ]

  private static let artifactDirectoryDescriptors: [String: WorkspaceArtifactDirectoryDescriptor] =
    [
      ".build": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "swiftpm_build", cleanupRisk: "recreatable"),
      "build": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "generic_build", cleanupRisk: "recreatable"),
      "dist": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "distribution_output", cleanupRisk: "recreatable"),
      "out": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "generic_output", cleanupRisk: "recreatable"),
      "target": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "rust_or_jvm_build", cleanupRisk: "recreatable"),
      "deriveddata": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "xcode_derived_data", cleanupRisk: "recreatable"),
      ".next": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "nextjs_build", cleanupRisk: "recreatable"),
      ".nuxt": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "nuxt_build", cleanupRisk: "recreatable"),
      ".svelte-kit": WorkspaceArtifactDirectoryDescriptor(
        category: "build_output", kind: "sveltekit_build", cleanupRisk: "recreatable"),
      "node_modules": WorkspaceArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "node_dependencies", cleanupRisk: "reinstallable"),
      "vendor": WorkspaceArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "vendored_dependencies", cleanupRisk: "review"),
      "pods": WorkspaceArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "cocoapods_dependencies", cleanupRisk: "reinstallable"
      ),
      "carthage": WorkspaceArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "carthage_dependencies", cleanupRisk: "reinstallable"),
      ".venv": WorkspaceArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "python_virtualenv", cleanupRisk: "reinstallable"),
      "venv": WorkspaceArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "python_virtualenv", cleanupRisk: "reinstallable"),
      ".cache": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "generic_cache", cleanupRisk: "recreatable"),
      "cache": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "generic_cache", cleanupRisk: "review"),
      ".turbo": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "turbo_cache", cleanupRisk: "recreatable"),
      ".parcel-cache": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "parcel_cache", cleanupRisk: "recreatable"),
      ".pnpm-store": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "pnpm_store", cleanupRisk: "recreatable"),
      ".pytest_cache": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "pytest_cache", cleanupRisk: "recreatable"),
      ".mypy_cache": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "mypy_cache", cleanupRisk: "recreatable"),
      ".ruff_cache": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "ruff_cache", cleanupRisk: "recreatable"),
      "__pycache__": WorkspaceArtifactDirectoryDescriptor(
        category: "cache", kind: "python_bytecode_cache", cleanupRisk: "recreatable"),
      "coverage": WorkspaceArtifactDirectoryDescriptor(
        category: "coverage_output", kind: "test_coverage", cleanupRisk: "recreatable"),
      ".nyc_output": WorkspaceArtifactDirectoryDescriptor(
        category: "coverage_output", kind: "nyc_coverage", cleanupRisk: "recreatable"),
      "tmp": WorkspaceArtifactDirectoryDescriptor(
        category: "temporary", kind: "temporary_directory", cleanupRisk: "review"),
      "temp": WorkspaceArtifactDirectoryDescriptor(
        category: "temporary", kind: "temporary_directory", cleanupRisk: "review"),
      ".tmp": WorkspaceArtifactDirectoryDescriptor(
        category: "temporary", kind: "temporary_directory", cleanupRisk: "review"),
      "generated": WorkspaceArtifactDirectoryDescriptor(
        category: "generated_candidate", kind: "generated_directory", cleanupRisk: "review"),
      "gen": WorkspaceArtifactDirectoryDescriptor(
        category: "generated_candidate", kind: "generated_directory", cleanupRisk: "review"),
    ]

  private static let archiveSkippedDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".hg",
    ".swiftpm",
    ".svn",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "deriveddata",
    "node_modules",
    "target",
    "vendor",
    "venv",
  ]

  private static let logSkippedDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".hg",
    ".swiftpm",
    ".svn",
    ".venv",
    "__pycache__",
    "deriveddata",
    "node_modules",
    "target",
    "vendor",
    "venv",
  ]

  private static let logDirectoryNames: Set<String> = [
    "log",
    "logs",
  ]

  private static let logDirectoryFileExtensions: Set<String> = [
    "",
    "err",
    "json",
    "jsonl",
    "log",
    "ndjson",
    "out",
    "text",
    "trace",
    "txt",
  ]

  private static let dataSkippedDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".hg",
    ".swiftpm",
    ".svn",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "deriveddata",
    "node_modules",
    "target",
    "vendor",
    "venv",
  ]

  private static let dataDirectoryNames: Set<String> = [
    "corpora",
    "corpus",
    "data",
    "dataset",
    "datasets",
    "exports",
    "fixtures",
    "imports",
    "sample-data",
    "samples",
    "seed",
    "seeds",
    "test-data",
    "testdata",
  ]

  private static let directoryScopedDataFileExtensions: Set<String> = [
    "json",
    "json5",
    "plist",
    "toml",
    "xml",
    "yaml",
    "yml",
  ]

  internal static let commandManifestNames: Set<String> = [
    "package.json",
    "Package.swift",
    "Cargo.toml",
    "go.mod",
    "Makefile",
    "makefile",
    "GNUmakefile",
    "Justfile",
    "justfile",
  ]

  private static let projectRootSkippedDirectoryNames = sourceSkippedDirectoryNames

  private static let sourceFileExtensions: [String: WorkspaceSourceFileDescriptor] = [
    "swift": WorkspaceSourceFileDescriptor(language: "swift", kind: "source"),
    "js": WorkspaceSourceFileDescriptor(language: "javascript", kind: "source"),
    "jsx": WorkspaceSourceFileDescriptor(language: "javascript", kind: "source"),
    "ts": WorkspaceSourceFileDescriptor(language: "typescript", kind: "source"),
    "tsx": WorkspaceSourceFileDescriptor(language: "typescript", kind: "source"),
    "mjs": WorkspaceSourceFileDescriptor(language: "javascript", kind: "source"),
    "cjs": WorkspaceSourceFileDescriptor(language: "javascript", kind: "source"),
    "py": WorkspaceSourceFileDescriptor(language: "python", kind: "source"),
    "rb": WorkspaceSourceFileDescriptor(language: "ruby", kind: "source"),
    "go": WorkspaceSourceFileDescriptor(language: "go", kind: "source"),
    "rs": WorkspaceSourceFileDescriptor(language: "rust", kind: "source"),
    "java": WorkspaceSourceFileDescriptor(language: "java", kind: "source"),
    "kt": WorkspaceSourceFileDescriptor(language: "kotlin", kind: "source"),
    "kts": WorkspaceSourceFileDescriptor(language: "kotlin", kind: "source"),
    "scala": WorkspaceSourceFileDescriptor(language: "scala", kind: "source"),
    "cs": WorkspaceSourceFileDescriptor(language: "csharp", kind: "source"),
    "php": WorkspaceSourceFileDescriptor(language: "php", kind: "source"),
    "dart": WorkspaceSourceFileDescriptor(language: "dart", kind: "source"),
    "ex": WorkspaceSourceFileDescriptor(language: "elixir", kind: "source"),
    "exs": WorkspaceSourceFileDescriptor(language: "elixir", kind: "source"),
    "erl": WorkspaceSourceFileDescriptor(language: "erlang", kind: "source"),
    "hrl": WorkspaceSourceFileDescriptor(language: "erlang", kind: "header"),
    "c": WorkspaceSourceFileDescriptor(language: "c", kind: "source"),
    "h": WorkspaceSourceFileDescriptor(language: "c", kind: "header"),
    "cpp": WorkspaceSourceFileDescriptor(language: "cpp", kind: "source"),
    "cc": WorkspaceSourceFileDescriptor(language: "cpp", kind: "source"),
    "cxx": WorkspaceSourceFileDescriptor(language: "cpp", kind: "source"),
    "hpp": WorkspaceSourceFileDescriptor(language: "cpp", kind: "header"),
    "hh": WorkspaceSourceFileDescriptor(language: "cpp", kind: "header"),
    "hxx": WorkspaceSourceFileDescriptor(language: "cpp", kind: "header"),
    "m": WorkspaceSourceFileDescriptor(language: "objective-c", kind: "source"),
    "mm": WorkspaceSourceFileDescriptor(language: "objective-cpp", kind: "source"),
    "sh": WorkspaceSourceFileDescriptor(language: "shell", kind: "script"),
    "bash": WorkspaceSourceFileDescriptor(language: "shell", kind: "script"),
    "zsh": WorkspaceSourceFileDescriptor(language: "shell", kind: "script"),
    "fish": WorkspaceSourceFileDescriptor(language: "fish", kind: "script"),
    "ps1": WorkspaceSourceFileDescriptor(language: "powershell", kind: "script"),
    "sql": WorkspaceSourceFileDescriptor(language: "sql", kind: "query"),
    "html": WorkspaceSourceFileDescriptor(language: "html", kind: "markup"),
    "htm": WorkspaceSourceFileDescriptor(language: "html", kind: "markup"),
    "css": WorkspaceSourceFileDescriptor(language: "css", kind: "style"),
    "scss": WorkspaceSourceFileDescriptor(language: "scss", kind: "style"),
    "sass": WorkspaceSourceFileDescriptor(language: "sass", kind: "style"),
    "less": WorkspaceSourceFileDescriptor(language: "less", kind: "style"),
    "vue": WorkspaceSourceFileDescriptor(language: "vue", kind: "component"),
    "svelte": WorkspaceSourceFileDescriptor(language: "svelte", kind: "component"),
    "astro": WorkspaceSourceFileDescriptor(language: "astro", kind: "component"),
  ]

  private static let assetFileExtensions: [String: WorkspaceAssetFileDescriptor] = [
    "png": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "jpg": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "jpeg": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "gif": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "webp": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "avif": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "heic": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "heif": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "tif": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "tiff": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "bmp": WorkspaceAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "ico": WorkspaceAssetFileDescriptor(category: "image", subtype: "icon"),
    "icns": WorkspaceAssetFileDescriptor(category: "image", subtype: "icon"),
    "svg": WorkspaceAssetFileDescriptor(category: "image", subtype: "vector"),
    "ttf": WorkspaceAssetFileDescriptor(category: "font", subtype: "truetype"),
    "otf": WorkspaceAssetFileDescriptor(category: "font", subtype: "opentype"),
    "woff": WorkspaceAssetFileDescriptor(category: "font", subtype: "webfont"),
    "woff2": WorkspaceAssetFileDescriptor(category: "font", subtype: "webfont"),
    "eot": WorkspaceAssetFileDescriptor(category: "font", subtype: "webfont"),
    "mp3": WorkspaceAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "m4a": WorkspaceAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "aac": WorkspaceAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "ogg": WorkspaceAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "opus": WorkspaceAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "flac": WorkspaceAssetFileDescriptor(category: "audio", subtype: "lossless"),
    "wav": WorkspaceAssetFileDescriptor(category: "audio", subtype: "waveform"),
    "mp4": WorkspaceAssetFileDescriptor(category: "video", subtype: "container"),
    "m4v": WorkspaceAssetFileDescriptor(category: "video", subtype: "container"),
    "mov": WorkspaceAssetFileDescriptor(category: "video", subtype: "container"),
    "webm": WorkspaceAssetFileDescriptor(category: "video", subtype: "container"),
    "avi": WorkspaceAssetFileDescriptor(category: "video", subtype: "container"),
    "mkv": WorkspaceAssetFileDescriptor(category: "video", subtype: "container"),
    "pdf": WorkspaceAssetFileDescriptor(category: "document", subtype: "pdf"),
    "key": WorkspaceAssetFileDescriptor(category: "document", subtype: "presentation"),
    "ppt": WorkspaceAssetFileDescriptor(category: "document", subtype: "presentation"),
    "pptx": WorkspaceAssetFileDescriptor(category: "document", subtype: "presentation"),
    "doc": WorkspaceAssetFileDescriptor(category: "document", subtype: "word_processing"),
    "docx": WorkspaceAssetFileDescriptor(category: "document", subtype: "word_processing"),
    "sketch": WorkspaceAssetFileDescriptor(category: "design", subtype: "source"),
    "fig": WorkspaceAssetFileDescriptor(category: "design", subtype: "source"),
    "psd": WorkspaceAssetFileDescriptor(category: "design", subtype: "source"),
    "ai": WorkspaceAssetFileDescriptor(category: "design", subtype: "source"),
    "xd": WorkspaceAssetFileDescriptor(category: "design", subtype: "source"),
  ]

  private static let archiveFileDescriptors: [WorkspaceArchiveFileDescriptor] = [
    WorkspaceArchiveFileDescriptor(
      suffix: ".tar.gz", fileExtension: "tar.gz", category: "archive", format: "tar_gzip",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".tar.bz2", fileExtension: "tar.bz2", category: "archive", format: "tar_bzip2",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".tar.xz", fileExtension: "tar.xz", category: "archive", format: "tar_xz",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".zip", fileExtension: "zip", category: "archive", format: "zip",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".jar", fileExtension: "jar", category: "application_package", format: "zip",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".war", fileExtension: "war", category: "application_package", format: "zip",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".ear", fileExtension: "ear", category: "application_package", format: "zip",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".tar", fileExtension: "tar", category: "archive", format: "tar",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".tgz", fileExtension: "tgz", category: "archive", format: "tar_gzip",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".tbz", fileExtension: "tbz", category: "archive", format: "tar_bzip2",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".tbz2", fileExtension: "tbz2", category: "archive", format: "tar_bzip2",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".txz", fileExtension: "txz", category: "archive", format: "tar_xz",
      listSupported: true),
    WorkspaceArchiveFileDescriptor(
      suffix: ".7z", fileExtension: "7z", category: "archive", format: "7z",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".rar", fileExtension: "rar", category: "archive", format: "rar",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".gz", fileExtension: "gz", category: "compressed_stream", format: "gzip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".bz2", fileExtension: "bz2", category: "compressed_stream", format: "bzip2",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".xz", fileExtension: "xz", category: "compressed_stream", format: "xz",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".dmg", fileExtension: "dmg", category: "disk_image", format: "dmg",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".pkg", fileExtension: "pkg", category: "installer", format: "pkg",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".mpkg", fileExtension: "mpkg", category: "installer", format: "mpkg",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".ipa", fileExtension: "ipa", category: "application_package", format: "zip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".apk", fileExtension: "apk", category: "application_package", format: "zip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".aab", fileExtension: "aab", category: "application_package", format: "zip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".nupkg", fileExtension: "nupkg", category: "application_package", format: "zip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".vsix", fileExtension: "vsix", category: "application_package", format: "zip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".xpi", fileExtension: "xpi", category: "application_package", format: "zip",
      listSupported: false),
    WorkspaceArchiveFileDescriptor(
      suffix: ".crx", fileExtension: "crx", category: "application_package", format: "crx",
      listSupported: false),
  ]

  private static let logExactFileDescriptors: [String: WorkspaceLogFileDescriptor] = [
    "access.log": WorkspaceLogFileDescriptor(
      category: "application_log", kind: "access", matchSource: "filename"),
    "debug.log": WorkspaceLogFileDescriptor(
      category: "application_log", kind: "debug", matchSource: "filename"),
    "error.log": WorkspaceLogFileDescriptor(
      category: "application_log", kind: "error", matchSource: "filename"),
    "npm-debug.log": WorkspaceLogFileDescriptor(
      category: "package_manager_log", kind: "debug", matchSource: "filename"),
    "pnpm-debug.log": WorkspaceLogFileDescriptor(
      category: "package_manager_log", kind: "debug", matchSource: "filename"),
    "yarn-error.log": WorkspaceLogFileDescriptor(
      category: "package_manager_log", kind: "error", matchSource: "filename"),
  ]

  private static let logFileExtensions: [String: WorkspaceLogFileDescriptor] = [
    "crash": WorkspaceLogFileDescriptor(
      category: "crash_report", kind: "crash", matchSource: "extension"),
    "err": WorkspaceLogFileDescriptor(
      category: "process_output", kind: "stderr", matchSource: "extension"),
    "ips": WorkspaceLogFileDescriptor(
      category: "crash_report", kind: "crash", matchSource: "extension"),
    "log": WorkspaceLogFileDescriptor(
      category: "application_log", kind: "log", matchSource: "extension"),
    "out": WorkspaceLogFileDescriptor(
      category: "process_output", kind: "stdout", matchSource: "extension"),
    "trace": WorkspaceLogFileDescriptor(
      category: "trace", kind: "trace", matchSource: "extension"),
  ]

  private static let dataFileExtensions: [String: WorkspaceDataFileDescriptor] = [
    "arrow": WorkspaceDataFileDescriptor(
      category: "columnar_data", format: "arrow", textReadable: false, jsonReadable: false),
    "avro": WorkspaceDataFileDescriptor(
      category: "record_data", format: "avro", textReadable: false, jsonReadable: false),
    "csv": WorkspaceDataFileDescriptor(
      category: "tabular_data", format: "csv", textReadable: true, jsonReadable: false),
    "db": WorkspaceDataFileDescriptor(
      category: "database", format: "sqlite_or_database", textReadable: false,
      jsonReadable: false),
    "db3": WorkspaceDataFileDescriptor(
      category: "database", format: "sqlite", textReadable: false, jsonReadable: false),
    "duckdb": WorkspaceDataFileDescriptor(
      category: "database", format: "duckdb", textReadable: false, jsonReadable: false),
    "feather": WorkspaceDataFileDescriptor(
      category: "columnar_data", format: "feather", textReadable: false, jsonReadable: false),
    "jsonl": WorkspaceDataFileDescriptor(
      category: "record_data", format: "json_lines", textReadable: true, jsonReadable: false,
      jsonLinesReadable: true),
    "ndjson": WorkspaceDataFileDescriptor(
      category: "record_data", format: "ndjson", textReadable: true, jsonReadable: false,
      jsonLinesReadable: true),
    "orc": WorkspaceDataFileDescriptor(
      category: "columnar_data", format: "orc", textReadable: false, jsonReadable: false),
    "parquet": WorkspaceDataFileDescriptor(
      category: "columnar_data", format: "parquet", textReadable: false, jsonReadable: false),
    "psv": WorkspaceDataFileDescriptor(
      category: "tabular_data", format: "pipe_separated_values", textReadable: true,
      jsonReadable: false),
    "sqlite": WorkspaceDataFileDescriptor(
      category: "database", format: "sqlite", textReadable: false, jsonReadable: false),
    "sqlite3": WorkspaceDataFileDescriptor(
      category: "database", format: "sqlite", textReadable: false, jsonReadable: false),
    "tsv": WorkspaceDataFileDescriptor(
      category: "tabular_data", format: "tab_separated_values", textReadable: true,
      jsonReadable: false),
    "xls": WorkspaceDataFileDescriptor(
      category: "spreadsheet_data", format: "excel", textReadable: false, jsonReadable: false),
    "xlsx": WorkspaceDataFileDescriptor(
      category: "spreadsheet_data", format: "excel", textReadable: false, jsonReadable: false),
  ]

  private static let directoryScopedDataFileDescriptors: [String: WorkspaceDataFileDescriptor] = [
    "json": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "json", textReadable: true, jsonReadable: true,
      matchSource: "data_directory"),
    "json5": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "json5", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "plist": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "plist", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "toml": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "toml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "xml": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "xml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "yaml": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "yaml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "yml": WorkspaceDataFileDescriptor(
      category: "structured_data", format: "yaml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
  ]

  private static let schemaSkippedDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".hg",
    ".swiftpm",
    ".svn",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "deriveddata",
    "node_modules",
    "target",
    "vendor",
    "venv",
  ]

  private static let schemaDirectoryNames: Set<String> = [
    "api",
    "apis",
    "asyncapi",
    "contract",
    "contracts",
    "database",
    "db",
    "graphql",
    "migration",
    "migrations",
    "openapi",
    "proto",
    "protobuf",
    "protos",
    "schema",
    "schemas",
    "swagger",
  ]

  private static let directoryScopedSchemaFileExtensions: Set<String> = [
    "json",
    "json5",
    "sql",
    "toml",
    "xml",
    "yaml",
    "yml",
  ]

  private static let schemaExactFileDescriptors: [String: WorkspaceSchemaFileDescriptor] = [
    "asyncapi.json": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "asyncapi", format: "json", jsonReadable: true,
      matchSource: "filename"),
    "asyncapi.yaml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "asyncapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "asyncapi.yml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "asyncapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "openapi.json": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "openapi", format: "json", jsonReadable: true,
      matchSource: "filename"),
    "openapi.yaml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "openapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "openapi.yml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "openapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "schema.graphql": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false, matchSource: "filename"),
    "schema.graphqls": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false, matchSource: "filename"),
    "schema.prisma": WorkspaceSchemaFileDescriptor(
      category: "database_schema", schemaKind: "prisma", format: "prisma",
      jsonReadable: false, matchSource: "filename"),
    "swagger.json": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "swagger", format: "json", jsonReadable: true,
      matchSource: "filename"),
    "swagger.yaml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "swagger", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "swagger.yml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "swagger", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
  ]

  private static let schemaFileExtensions: [String: WorkspaceSchemaFileDescriptor] = [
    "avdl": WorkspaceSchemaFileDescriptor(
      category: "data_schema", schemaKind: "avro_idl", format: "avro_idl",
      jsonReadable: false),
    "avpr": WorkspaceSchemaFileDescriptor(
      category: "data_schema", schemaKind: "avro_protocol", format: "json",
      jsonReadable: true),
    "avsc": WorkspaceSchemaFileDescriptor(
      category: "data_schema", schemaKind: "avro_schema", format: "json",
      jsonReadable: true),
    "capnp": WorkspaceSchemaFileDescriptor(
      category: "data_schema", schemaKind: "capn_proto", format: "capnp",
      jsonReadable: false),
    "fbs": WorkspaceSchemaFileDescriptor(
      category: "data_schema", schemaKind: "flatbuffers", format: "flatbuffers",
      jsonReadable: false),
    "gql": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false),
    "graphql": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false),
    "graphqls": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false),
    "prisma": WorkspaceSchemaFileDescriptor(
      category: "database_schema", schemaKind: "prisma", format: "prisma",
      jsonReadable: false),
    "proto": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "protobuf", format: "protobuf",
      jsonReadable: false),
    "raml": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "raml", format: "raml", jsonReadable: false),
    "thrift": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "thrift", format: "thrift",
      jsonReadable: false),
    "wsdl": WorkspaceSchemaFileDescriptor(
      category: "api_contract", schemaKind: "wsdl", format: "xml", jsonReadable: false),
    "xsd": WorkspaceSchemaFileDescriptor(
      category: "data_schema", schemaKind: "xml_schema", format: "xml", jsonReadable: false),
  ]

  private static let infraSkippedDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".hg",
    ".pulumi",
    ".serverless",
    ".sst",
    ".svn",
    ".swiftpm",
    ".terraform",
    ".venv",
    "__pycache__",
    "build",
    "cdk.out",
    "coverage",
    "deriveddata",
    "node_modules",
    "target",
    "vendor",
    "venv",
  ]

  private static let infraAlwaysIncludedDirectoryNames: Set<String> = [
    ".devcontainer"
  ]

  private static let infraDirectoryNames: Set<String> = [
    ".devcontainer",
    "chart",
    "charts",
    "container",
    "containers",
    "deploy",
    "deployment",
    "deployments",
    "devcontainer",
    "docker",
    "helm",
    "iac",
    "infra",
    "infrastructure",
    "k8s",
    "kube",
    "kubernetes",
    "manifest",
    "manifests",
    "ops",
    "terraform",
  ]

  private static let directoryScopedInfraFileExtensions: Set<String> = [
    "hcl",
    "json",
    "jsonc",
    "toml",
    "yaml",
    "yml",
  ]

  private static let infraExactFileDescriptors: [String: WorkspaceInfraFileDescriptor] = [
    "cdk.json": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "aws_cdk", kind: "project_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "chart.yaml": WorkspaceInfraFileDescriptor(
      category: "package_deployment", provider: "helm", kind: "chart",
      format: "yaml", matchSource: "filename"),
    "compose.yaml": WorkspaceInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "compose.yml": WorkspaceInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "containerfile": WorkspaceInfraFileDescriptor(
      category: "container", provider: "containerfile", kind: "image_build",
      format: "containerfile", matchSource: "filename"),
    "devcontainer.json": WorkspaceInfraFileDescriptor(
      category: "development_container", provider: "devcontainer", kind: "dev_environment",
      format: "json", matchSource: "filename", jsonReadable: true),
    "docker-compose.yaml": WorkspaceInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "docker-compose.yml": WorkspaceInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "dockerfile": WorkspaceInfraFileDescriptor(
      category: "container", provider: "docker", kind: "image_build", format: "dockerfile",
      matchSource: "filename"),
    "fly.toml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "fly", kind: "deployment_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
    "kustomization.yaml": WorkspaceInfraFileDescriptor(
      category: "orchestration", provider: "kustomize", kind: "kustomization",
      format: "yaml", matchSource: "filename"),
    "kustomization.yml": WorkspaceInfraFileDescriptor(
      category: "orchestration", provider: "kustomize", kind: "kustomization",
      format: "yaml", matchSource: "filename"),
    "netlify.toml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "netlify", kind: "deployment_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
    "procfile": WorkspaceInfraFileDescriptor(
      category: "process_deployment", provider: "process_manager", kind: "process_profile",
      format: "procfile", matchSource: "filename"),
    "pulumi.json": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "pulumi", kind: "stack_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "pulumi.yaml": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "pulumi", kind: "stack_config",
      format: "yaml", matchSource: "filename"),
    "pulumi.yml": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "pulumi", kind: "stack_config",
      format: "yaml", matchSource: "filename"),
    "railway.json": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "railway", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "render.yaml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "render", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "render.yml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "render", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "samconfig.toml": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "aws_sam", kind: "project_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
    "serverless.json": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "serverless", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "serverless.yaml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "serverless", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "serverless.yml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "serverless", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "skaffold.yaml": WorkspaceInfraFileDescriptor(
      category: "orchestration", provider: "skaffold", kind: "pipeline",
      format: "yaml", matchSource: "filename"),
    "skaffold.yml": WorkspaceInfraFileDescriptor(
      category: "orchestration", provider: "skaffold", kind: "pipeline",
      format: "yaml", matchSource: "filename"),
    "tiltfile": WorkspaceInfraFileDescriptor(
      category: "development_orchestration", provider: "tilt", kind: "pipeline",
      format: "starlark", matchSource: "filename"),
    "vercel.json": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "vercel", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "wrangler.json": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "cloudflare", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "wrangler.jsonc": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "cloudflare", kind: "deployment_config",
      format: "jsonc", matchSource: "filename"),
    "wrangler.toml": WorkspaceInfraFileDescriptor(
      category: "platform_deployment", provider: "cloudflare", kind: "deployment_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
  ]

  private static let infraFileExtensions: [String: WorkspaceInfraFileDescriptor] = [
    "tf": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "terraform", kind: "module",
      format: "hcl", matchSource: "extension"),
    "tfvars": WorkspaceInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "terraform", kind: "variables",
      format: "hcl", matchSource: "extension"),
  ]

  private static let configExactFileDescriptors: [String: WorkspaceConfigFileDescriptor] = [
    ".editorconfig": WorkspaceConfigFileDescriptor(
      tool: "editorconfig", category: "editor", matchSource: "filename"),
    ".swift-format": WorkspaceConfigFileDescriptor(
      tool: "swift-format", category: "formatter", matchSource: "filename"),
    "swift-format.json": WorkspaceConfigFileDescriptor(
      tool: "swift-format", category: "formatter", matchSource: "filename"),
    ".swiftlint.yml": WorkspaceConfigFileDescriptor(
      tool: "swiftlint", category: "linter", matchSource: "filename"),
    ".swiftlint.yaml": WorkspaceConfigFileDescriptor(
      tool: "swiftlint", category: "linter", matchSource: "filename"),
    ".prettierrc": WorkspaceConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.json": WorkspaceConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.jsonc": WorkspaceConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.yml": WorkspaceConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.yaml": WorkspaceConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.toml": WorkspaceConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".eslintrc": WorkspaceConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    ".eslintrc.json": WorkspaceConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    ".eslintrc.yml": WorkspaceConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    ".eslintrc.yaml": WorkspaceConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    "biome.json": WorkspaceConfigFileDescriptor(
      tool: "biome", category: "formatter_linter", matchSource: "filename"),
    "biome.jsonc": WorkspaceConfigFileDescriptor(
      tool: "biome", category: "formatter_linter", matchSource: "filename"),
    "rome.json": WorkspaceConfigFileDescriptor(
      tool: "rome", category: "formatter_linter", matchSource: "filename"),
    "tsconfig.json": WorkspaceConfigFileDescriptor(
      tool: "typescript", category: "compiler", matchSource: "filename"),
    "jsconfig.json": WorkspaceConfigFileDescriptor(
      tool: "javascript", category: "language_service", matchSource: "filename"),
    ".stylelintrc": WorkspaceConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".stylelintrc.json": WorkspaceConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".stylelintrc.yml": WorkspaceConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".stylelintrc.yaml": WorkspaceConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".browserslistrc": WorkspaceConfigFileDescriptor(
      tool: "browserslist", category: "compatibility", matchSource: "filename"),
    "browserslist": WorkspaceConfigFileDescriptor(
      tool: "browserslist", category: "compatibility", matchSource: "filename"),
    "ruff.toml": WorkspaceConfigFileDescriptor(
      tool: "ruff", category: "linter", matchSource: "filename"),
    ".ruff.toml": WorkspaceConfigFileDescriptor(
      tool: "ruff", category: "linter", matchSource: "filename"),
    "mypy.ini": WorkspaceConfigFileDescriptor(
      tool: "mypy", category: "type_checker", matchSource: "filename"),
    ".mypy.ini": WorkspaceConfigFileDescriptor(
      tool: "mypy", category: "type_checker", matchSource: "filename"),
    ".flake8": WorkspaceConfigFileDescriptor(
      tool: "flake8", category: "linter", matchSource: "filename"),
    "tox.ini": WorkspaceConfigFileDescriptor(
      tool: "tox", category: "test_runner", matchSource: "filename"),
    "pytest.ini": WorkspaceConfigFileDescriptor(
      tool: "pytest", category: "test_runner", matchSource: "filename"),
    ".pylintrc": WorkspaceConfigFileDescriptor(
      tool: "pylint", category: "linter", matchSource: "filename"),
    "pyrightconfig.json": WorkspaceConfigFileDescriptor(
      tool: "pyright", category: "type_checker", matchSource: "filename"),
    "rustfmt.toml": WorkspaceConfigFileDescriptor(
      tool: "rustfmt", category: "formatter", matchSource: "filename"),
    ".rustfmt.toml": WorkspaceConfigFileDescriptor(
      tool: "rustfmt", category: "formatter", matchSource: "filename"),
    "clippy.toml": WorkspaceConfigFileDescriptor(
      tool: "clippy", category: "linter", matchSource: "filename"),
    ".clippy.toml": WorkspaceConfigFileDescriptor(
      tool: "clippy", category: "linter", matchSource: "filename"),
    "golangci.yml": WorkspaceConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    "golangci.yaml": WorkspaceConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    ".golangci.yml": WorkspaceConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    ".golangci.yaml": WorkspaceConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    ".yamllint.yml": WorkspaceConfigFileDescriptor(
      tool: "yamllint", category: "linter", matchSource: "filename"),
    ".yamllint.yaml": WorkspaceConfigFileDescriptor(
      tool: "yamllint", category: "linter", matchSource: "filename"),
    ".markdownlint.json": WorkspaceConfigFileDescriptor(
      tool: "markdownlint", category: "linter", matchSource: "filename"),
    ".markdownlint.yml": WorkspaceConfigFileDescriptor(
      tool: "markdownlint", category: "linter", matchSource: "filename"),
    ".markdownlint.yaml": WorkspaceConfigFileDescriptor(
      tool: "markdownlint", category: "linter", matchSource: "filename"),
    ".npmrc": WorkspaceConfigFileDescriptor(
      tool: "npm", category: "package_manager", matchSource: "filename"),
    ".yarnrc": WorkspaceConfigFileDescriptor(
      tool: "yarn", category: "package_manager", matchSource: "filename"),
    ".yarnrc.yml": WorkspaceConfigFileDescriptor(
      tool: "yarn", category: "package_manager", matchSource: "filename"),
    ".pnpmrc": WorkspaceConfigFileDescriptor(
      tool: "pnpm", category: "package_manager", matchSource: "filename"),
    ".nvmrc": WorkspaceConfigFileDescriptor(
      tool: "node", category: "toolchain", matchSource: "filename"),
    ".node-version": WorkspaceConfigFileDescriptor(
      tool: "node", category: "toolchain", matchSource: "filename"),
    ".ruby-version": WorkspaceConfigFileDescriptor(
      tool: "ruby", category: "toolchain", matchSource: "filename"),
    ".python-version": WorkspaceConfigFileDescriptor(
      tool: "python", category: "toolchain", matchSource: "filename"),
    ".tool-versions": WorkspaceConfigFileDescriptor(
      tool: "asdf", category: "toolchain", matchSource: "filename"),
    ".mise.toml": WorkspaceConfigFileDescriptor(
      tool: "mise", category: "toolchain", matchSource: "filename"),
    ".mise.local.toml": WorkspaceConfigFileDescriptor(
      tool: "mise", category: "toolchain", matchSource: "filename"),
    ".sdkmanrc": WorkspaceConfigFileDescriptor(
      tool: "sdkman", category: "toolchain", matchSource: "filename"),
    ".gitignore": WorkspaceConfigFileDescriptor(
      tool: "git", category: "source_control", matchSource: "filename"),
    ".gitattributes": WorkspaceConfigFileDescriptor(
      tool: "git", category: "source_control", matchSource: "filename"),
  ]

  private static let ignoreFileDescriptors: [String: WorkspaceIgnoreFileDescriptor] = [
    ".gitignore": WorkspaceIgnoreFileDescriptor(
      provider: "git", category: "source_control_ignore", matchSource: "filename"),
    ".git-blame-ignore-revs": WorkspaceIgnoreFileDescriptor(
      provider: "git", category: "source_control_history_ignore", matchSource: "filename"),
    ".ignore": WorkspaceIgnoreFileDescriptor(
      provider: "generic", category: "search_ignore", matchSource: "filename"),
    ".rgignore": WorkspaceIgnoreFileDescriptor(
      provider: "ripgrep", category: "search_ignore", matchSource: "filename"),
    ".fdignore": WorkspaceIgnoreFileDescriptor(
      provider: "fd", category: "search_ignore", matchSource: "filename"),
    ".dockerignore": WorkspaceIgnoreFileDescriptor(
      provider: "docker", category: "build_context_ignore", matchSource: "filename"),
    ".npmignore": WorkspaceIgnoreFileDescriptor(
      provider: "npm", category: "package_publish_ignore", matchSource: "filename"),
    ".eslintignore": WorkspaceIgnoreFileDescriptor(
      provider: "eslint", category: "linter_ignore", matchSource: "filename"),
    ".prettierignore": WorkspaceIgnoreFileDescriptor(
      provider: "prettier", category: "formatter_ignore", matchSource: "filename"),
    ".stylelintignore": WorkspaceIgnoreFileDescriptor(
      provider: "stylelint", category: "linter_ignore", matchSource: "filename"),
    ".markdownlintignore": WorkspaceIgnoreFileDescriptor(
      provider: "markdownlint", category: "linter_ignore", matchSource: "filename"),
    ".yamllintignore": WorkspaceIgnoreFileDescriptor(
      provider: "yamllint", category: "linter_ignore", matchSource: "filename"),
    ".helmignore": WorkspaceIgnoreFileDescriptor(
      provider: "helm", category: "package_ignore", matchSource: "filename"),
    ".terraformignore": WorkspaceIgnoreFileDescriptor(
      provider: "terraform", category: "package_ignore", matchSource: "filename"),
    ".gcloudignore": WorkspaceIgnoreFileDescriptor(
      provider: "gcloud", category: "deploy_ignore", matchSource: "filename"),
    ".ebignore": WorkspaceIgnoreFileDescriptor(
      provider: "elastic_beanstalk", category: "deploy_ignore", matchSource: "filename"),
    ".slugignore": WorkspaceIgnoreFileDescriptor(
      provider: "heroku", category: "deploy_ignore", matchSource: "filename"),
    ".vercelignore": WorkspaceIgnoreFileDescriptor(
      provider: "vercel", category: "deploy_ignore", matchSource: "filename"),
    ".netlifyignore": WorkspaceIgnoreFileDescriptor(
      provider: "netlify", category: "deploy_ignore", matchSource: "filename"),
    ".cursorignore": WorkspaceIgnoreFileDescriptor(
      provider: "cursor", category: "agent_context_ignore", matchSource: "filename"),
    ".aiexclude": WorkspaceIgnoreFileDescriptor(
      provider: "agent", category: "agent_context_ignore", matchSource: "filename"),
  ]

  internal func directoryStatsDepth(_ relativePath: String) -> Int {
    relativePath.split(separator: "/").count - 1
  }

  internal func directoryStatsGroupPath(
    rootWorkspaceRelativePath: String,
    relativeToRoot: String
  ) -> String {
    guard let first = relativeToRoot.split(separator: "/").first else {
      return rootWorkspaceRelativePath
    }
    if rootWorkspaceRelativePath == "." {
      return String(first)
    }
    return "\(rootWorkspaceRelativePath)/\(first)"
  }

  internal func directoryStatsGroupName(
    _ workspaceRelativePath: String,
    rootWorkspaceRelativePath: String
  ) -> String {
    if workspaceRelativePath == rootWorkspaceRelativePath {
      return "."
    }
    return (workspaceRelativePath as NSString).lastPathComponent
  }

  internal func collectWorkspaceEmptyDirectories(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    scannedDirectoryCount: inout Int,
    hiddenSkippedCount: inout Int,
    emptyDirectories: inout [WorkspaceEmptyDirectoryInfo],
    scanTruncated: inout Bool
  ) throws {
    guard !scanTruncated else {
      return
    }

    let directoryInfo = try fileInfo(url: directory)
    scannedDirectoryCount += 1
    let children = try sortedDirectoryChildren(directory, includeHidden: true)
    if children.isEmpty {
      emptyDirectories.append(
        WorkspaceEmptyDirectoryInfo(
          path: directoryInfo.path,
          workspaceRelativePath: directoryInfo.workspaceRelativePath,
          name: directory.lastPathComponent.isEmpty ? "." : directory.lastPathComponent,
          depth: currentDepth,
          isRoot: currentDepth == 0,
          modifiedAt: directoryInfo.modifiedAt
        ))
      return
    }

    guard currentDepth < maxDepth else {
      return
    }

    for child in children {
      guard !scanTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }
      scannedEntries += 1

      let childInfo = try fileInfo(url: child)
      guard childInfo.type == "directory", !childInfo.isSymlink else {
        continue
      }
      if child.lastPathComponent.hasPrefix("."), !includeHidden {
        hiddenSkippedCount += 1
        continue
      }

      try collectWorkspaceEmptyDirectories(
        directory: child,
        currentDepth: currentDepth + 1,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        scannedDirectoryCount: &scannedDirectoryCount,
        hiddenSkippedCount: &hiddenSkippedCount,
        emptyDirectories: &emptyDirectories,
        scanTruncated: &scanTruncated
      )
    }
  }

  internal func collectWorkspaceArtifactDirectories(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    hiddenSkippedCount: inout Int,
    artifactDirectories: inout [WorkspaceArtifactDirectoryInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      let name = child.lastPathComponent
      let info = try fileInfo(url: child)
      guard info.type == "directory", !info.isSymlink else {
        scannedEntries += 1
        continue
      }

      if name.hasPrefix("."), !includeHidden {
        hiddenSkippedCount += 1
        continue
      }

      scannedEntries += 1
      if let descriptor = artifactDirectoryDescriptor(forDirectoryName: name) {
        guard artifactDirectories.count < maxResults else {
          resultTruncated = true
          return
        }
        artifactDirectories.append(
          WorkspaceArtifactDirectoryInfo(
            info: info,
            category: descriptor.category,
            kind: descriptor.kind,
            cleanupRisk: descriptor.cleanupRisk,
            matchSource: "directory_name"
          ))
        continue
      }

      if currentDepth < maxDepth {
        try collectWorkspaceArtifactDirectories(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          hiddenSkippedCount: &hiddenSkippedCount,
          artifactDirectories: &artifactDirectories,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  private func artifactDirectoryDescriptor(forDirectoryName name: String)
    -> WorkspaceArtifactDirectoryDescriptor?
  {
    Self.artifactDirectoryDescriptors[name.lowercased()]
  }

  internal func collectTodoMatches(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    markers: [String],
    caseSensitive: Bool,
    includeHidden: Bool,
    maxFiles: Int,
    maxMatches: Int,
    maxBytesPerFile: Int,
    filesScanned: inout Int,
    filesSkipped: inout Int,
    bytesScanned: inout Int,
    truncatedFiles: inout Int,
    matches: inout [WorkspaceTodoMatch],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard !truncated else {
        return
      }

      let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: resolved)
      if info.type == "directory" && !info.isSymlink {
        if currentDepth < maxDepth {
          try collectTodoMatches(
            directory: resolved,
            currentDepth: currentDepth + 1,
            maxDepth: maxDepth,
            markers: markers,
            caseSensitive: caseSensitive,
            includeHidden: includeHidden,
            maxFiles: maxFiles,
            maxMatches: maxMatches,
            maxBytesPerFile: maxBytesPerFile,
            filesScanned: &filesScanned,
            filesSkipped: &filesSkipped,
            bytesScanned: &bytesScanned,
            truncatedFiles: &truncatedFiles,
            matches: &matches,
            truncated: &truncated
          )
        }
        continue
      }

      try scanTodoFileIfAllowed(
        url: resolved,
        info: info,
        markers: markers,
        caseSensitive: caseSensitive,
        maxFiles: maxFiles,
        maxMatches: maxMatches,
        maxBytesPerFile: maxBytesPerFile,
        filesScanned: &filesScanned,
        filesSkipped: &filesSkipped,
        bytesScanned: &bytesScanned,
        truncatedFiles: &truncatedFiles,
        matches: &matches,
        truncated: &truncated
      )
    }
  }

  internal func scanTodoFileIfAllowed(
    url: URL,
    info: FileInfo,
    markers: [String],
    caseSensitive: Bool,
    maxFiles: Int,
    maxMatches: Int,
    maxBytesPerFile: Int,
    filesScanned: inout Int,
    filesSkipped: inout Int,
    bytesScanned: inout Int,
    truncatedFiles: inout Int,
    matches: inout [WorkspaceTodoMatch],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }
    guard info.type == "file" else {
      filesSkipped += 1
      return
    }
    guard filesScanned < maxFiles else {
      truncated = true
      return
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let limitedData: Data
    if data.count > maxBytesPerFile {
      limitedData = Data(data.prefix(maxBytesPerFile))
      truncatedFiles += 1
    } else {
      limitedData = data
    }
    bytesScanned += limitedData.count
    filesScanned += 1

    guard !limitedData.contains(0) else {
      filesSkipped += 1
      return
    }

    let content = String(decoding: limitedData, as: UTF8.self)
    appendTodoMatches(
      content: content,
      fileInfo: info,
      markers: markers,
      caseSensitive: caseSensitive,
      maxMatches: maxMatches,
      fileTruncated: data.count > maxBytesPerFile,
      matches: &matches,
      truncated: &truncated
    )
  }

  private func appendTodoMatches(
    content: String,
    fileInfo: FileInfo,
    markers: [String],
    caseSensitive: Bool,
    maxMatches: Int,
    fileTruncated: Bool,
    matches: inout [WorkspaceTodoMatch],
    truncated: inout Bool
  ) {
    let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    for (lineIndex, line) in content.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      var lineMatches: [(markerIndex: Int, range: Range<Substring.Index>)] = []
      for (markerIndex, marker) in markers.enumerated() {
        if let range = firstTodoMarkerRange(in: line, marker: marker, options: options) {
          lineMatches.append((markerIndex: markerIndex, range: range))
        }
      }

      lineMatches.sort { lhs, rhs in
        if lhs.range.lowerBound != rhs.range.lowerBound {
          return lhs.range.lowerBound < rhs.range.lowerBound
        }
        return lhs.markerIndex < rhs.markerIndex
      }

      for lineMatch in lineMatches {
        guard matches.count < maxMatches else {
          truncated = true
          return
        }

        matches.append(
          WorkspaceTodoMatch(
            marker: markers[lineMatch.markerIndex],
            path: fileInfo.path,
            workspaceRelativePath: fileInfo.workspaceRelativePath,
            line: lineIndex + 1,
            column: line.distance(from: line.startIndex, to: lineMatch.range.lowerBound) + 1,
            preview: String(line.prefix(300)),
            fileTruncated: fileTruncated
          ))
      }
    }
  }

  private func firstTodoMarkerRange(
    in line: Substring,
    marker: String,
    options: String.CompareOptions
  ) -> Range<Substring.Index>? {
    var lowerBound = line.startIndex
    while lowerBound < line.endIndex {
      guard let range = line[lowerBound...].range(of: marker, options: options) else {
        return nil
      }
      if isTodoMarkerToken(in: line, range: range) {
        return range
      }
      lowerBound = range.upperBound
    }
    return nil
  }

  private func isTodoMarkerToken(
    in line: Substring,
    range: Range<Substring.Index>
  ) -> Bool {
    if range.lowerBound > line.startIndex {
      let previous = line[line.index(before: range.lowerBound)]
      if isTodoMarkerWordCharacter(previous) {
        return false
      }
    }

    if range.upperBound < line.endIndex {
      let next = line[range.upperBound]
      if isTodoMarkerWordCharacter(next) {
        return false
      }
    }

    return true
  }

  private func isTodoMarkerWordCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      (scalar.value >= 48 && scalar.value <= 57)
        || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
        || scalar.value == 95
    }
  }

  internal func collectWorkspaceEnvFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHiddenDirectories: Bool,
    maxFiles: Int,
    maxKeysPerFile: Int,
    maxBytesPerFile: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    envFiles: inout [WorkspaceEnvFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      if scannedEntries >= maxScanEntries {
        scanTruncated = true
        return
      }
      scannedEntries += 1

      let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: resolved)
      if info.type == "directory" && !info.isSymlink {
        guard currentDepth < maxDepth else {
          continue
        }
        guard includeHiddenDirectories || !child.lastPathComponent.hasPrefix(".") else {
          continue
        }
        try collectWorkspaceEnvFiles(
          directory: resolved,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHiddenDirectories: includeHiddenDirectories,
          maxFiles: maxFiles,
          maxKeysPerFile: maxKeysPerFile,
          maxBytesPerFile: maxBytesPerFile,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          envFiles: &envFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
        continue
      }

      guard info.type == "file", isEnvFileName(child.lastPathComponent) else {
        continue
      }
      guard envFiles.count < maxFiles else {
        resultTruncated = true
        return
      }
      envFiles.append(
        try parseWorkspaceEnvFile(
          url: resolved,
          info: info,
          maxKeysPerFile: maxKeysPerFile,
          maxBytesPerFile: maxBytesPerFile
        ))
    }
  }

  internal func parseWorkspaceEnvFile(
    url: URL,
    info: FileInfo,
    maxKeysPerFile: Int,
    maxBytesPerFile: Int
  ) throws -> WorkspaceEnvFileInfo {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let fileTruncated = data.count > maxBytesPerFile
    let limitedData = fileTruncated ? Data(data.prefix(maxBytesPerFile)) : data
    guard !limitedData.contains(0) else {
      return WorkspaceEnvFileInfo(
        path: info.path,
        workspaceRelativePath: info.workspaceRelativePath,
        sizeBytes: info.size,
        modifiedAt: info.modifiedAt,
        bytesScanned: limitedData.count,
        fileTruncated: fileTruncated,
        keysTruncated: false,
        invalidLineCount: 0,
        parseError: "File appears to be binary.",
        keys: []
      )
    }
    guard let content = String(data: limitedData, encoding: .utf8) else {
      return WorkspaceEnvFileInfo(
        path: info.path,
        workspaceRelativePath: info.workspaceRelativePath,
        sizeBytes: info.size,
        modifiedAt: info.modifiedAt,
        bytesScanned: limitedData.count,
        fileTruncated: fileTruncated,
        keysTruncated: false,
        invalidLineCount: 0,
        parseError: "File is not valid UTF-8.",
        keys: []
      )
    }

    var keys: [WorkspaceEnvKeyInfo] = []
    var invalidLineCount = 0
    var keysTruncated = false

    for (lineIndex, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      guard let parsed = parseEnvLine(String(rawLine), line: lineIndex + 1) else {
        continue
      }
      switch parsed {
      case .invalid:
        invalidLineCount += 1
      case .key(let key):
        guard keys.count < maxKeysPerFile else {
          keysTruncated = true
          break
        }
        keys.append(key)
      }
    }

    return WorkspaceEnvFileInfo(
      path: info.path,
      workspaceRelativePath: info.workspaceRelativePath,
      sizeBytes: info.size,
      modifiedAt: info.modifiedAt,
      bytesScanned: limitedData.count,
      fileTruncated: fileTruncated,
      keysTruncated: keysTruncated,
      invalidLineCount: invalidLineCount,
      parseError: nil,
      keys: keys
    )
  }

  private func parseEnvLine(_ rawLine: String, line: Int) -> ParsedEnvLine? {
    var text = rawLine.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !text.hasPrefix("#") else {
      return nil
    }

    var exported = false
    if text.hasPrefix("export ") {
      exported = true
      text = String(text.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
    }

    let keyText: String
    let hasValue: Bool
    let valueEmpty: Bool
    if let equalsIndex = text.firstIndex(of: "=") {
      keyText = String(text[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
      hasValue = true
      valueEmpty = text[text.index(after: equalsIndex)...].isEmpty
    } else {
      keyText = text.trimmingCharacters(in: .whitespaces)
      hasValue = false
      valueEmpty = true
    }

    guard isEnvKeyName(keyText) else {
      return .invalid
    }

    return .key(
      WorkspaceEnvKeyInfo(
        name: keyText,
        line: line,
        exported: exported,
        hasValue: hasValue,
        valueEmpty: valueEmpty
      ))
  }

  internal func isEnvFileName(_ name: String) -> Bool {
    name == ".env"
      || name.hasPrefix(".env.")
      || name.hasSuffix(".env")
      || name.contains(".env.")
  }

  private func isEnvKeyName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first else {
      return false
    }
    guard isEnvKeyFirstScalar(first) else {
      return false
    }
    return name.unicodeScalars.dropFirst().allSatisfy(isEnvKeyScalar)
  }

  private func isEnvKeyFirstScalar(_ scalar: UnicodeScalar) -> Bool {
    (scalar.value >= 65 && scalar.value <= 90)
      || (scalar.value >= 97 && scalar.value <= 122)
      || scalar.value == 95
  }

  private func isEnvKeyScalar(_ scalar: UnicodeScalar) -> Bool {
    isEnvKeyFirstScalar(scalar) || (scalar.value >= 48 && scalar.value <= 57)
  }

  internal func collectWorkspaceDependencyFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    dependencyFiles: inout [WorkspaceDependencyFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let info = try fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        if info.type == "directory" {
          continue
        }
        if dependencyFileDescriptor(for: name) == nil {
          continue
        }
      }

      if let descriptor = dependencyFileDescriptor(for: name) {
        guard dependencyFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        dependencyFiles.append(
          WorkspaceDependencyFileInfo(
            info: info,
            ecosystem: descriptor.ecosystem,
            role: descriptor.role
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceDependencyFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          dependencyFiles: &dependencyFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func collectWorkspaceProjectDependencyFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    dependencyFiles: inout [WorkspaceDependencyFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.projectRootSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        if info.type == "directory" {
          continue
        }
        if dependencyFileDescriptor(for: name) == nil {
          continue
        }
      }

      if let descriptor = dependencyFileDescriptor(for: name) {
        guard dependencyFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        dependencyFiles.append(
          WorkspaceDependencyFileInfo(
            info: info,
            ecosystem: descriptor.ecosystem,
            role: descriptor.role
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceProjectDependencyFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          dependencyFiles: &dependencyFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func dependencyFileDescriptor(for name: String) -> WorkspaceDependencyFileDescriptor? {
    if let descriptor = Self.dependencyFileDescriptors.first(where: { $0.name == name }) {
      return descriptor
    }

    let lowercased = name.lowercased()
    if lowercased.hasPrefix("requirements-"), lowercased.hasSuffix(".txt") {
      return WorkspaceDependencyFileDescriptor(
        name: name,
        ecosystem: "python",
        role: "requirements"
      )
    }
    return nil
  }

  internal func groupedWorkspaceProjectRoots(
    from dependencyFiles: [WorkspaceDependencyFileInfo]
  ) -> [WorkspaceProjectRootInfo] {
    var grouped: [String: [WorkspaceDependencyFileInfo]] = [:]
    for dependencyFile in dependencyFiles {
      let directory = (dependencyFile.info.workspaceRelativePath as NSString)
        .deletingLastPathComponent
      let normalizedDirectory = directory.isEmpty || directory == "." ? "." : directory
      grouped[normalizedDirectory, default: []].append(dependencyFile)
    }

    return grouped.map { directory, files in
      let sortedFiles = files.sorted {
        $0.info.workspaceRelativePath.localizedStandardCompare($1.info.workspaceRelativePath)
          == .orderedAscending
      }
      let ecosystems = Array(Set(sortedFiles.map(\.ecosystem))).sorted()
      let manifestFiles = sortedFiles.filter { $0.role == "manifest" || $0.role == "requirements" }
      let lockFiles = sortedFiles.filter { $0.role == "lock" }
      let checksumFiles = sortedFiles.filter { $0.role == "checksum" }
      return WorkspaceProjectRootInfo(
        path: projectRootAbsolutePath(directory),
        workspaceRelativePath: directory,
        ecosystems: ecosystems,
        manifestFiles: manifestFiles.map(\.info.workspaceRelativePath),
        lockFiles: lockFiles.map(\.info.workspaceRelativePath),
        checksumFiles: checksumFiles.map(\.info.workspaceRelativePath),
        dependencyFiles: sortedFiles.map {
          WorkspaceProjectDependencyFileInfo(
            workspaceRelativePath: $0.info.workspaceRelativePath,
            name: ($0.info.workspaceRelativePath as NSString).lastPathComponent,
            ecosystem: $0.ecosystem,
            role: $0.role
          )
        },
        isWorkspaceRoot: directory == "."
      )
    }
    .sorted {
      $0.workspaceRelativePath.localizedStandardCompare($1.workspaceRelativePath)
        == .orderedAscending
    }
  }

  private func projectRootAbsolutePath(_ workspaceRelativePath: String) -> String {
    if workspaceRelativePath == "." {
      return configuration.workspaceDirectory.standardizedFileURL.path
    }
    return configuration.workspaceDirectory
      .appendingPathComponent(workspaceRelativePath)
      .standardizedFileURL
      .path
  }

  internal func collectWorkspaceDocumentationFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    documentationFiles: inout [WorkspaceDocumentationFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let info = try fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = documentationDescriptor(for: info.workspaceRelativePath)
      {
        guard documentationFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        documentationFiles.append(
          WorkspaceDocumentationFileInfo(
            info: info,
            category: descriptor.category,
            source: descriptor.source
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceDocumentationFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          documentationFiles: &documentationFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func documentationDescriptor(for workspaceRelativePath: String)
    -> WorkspaceDocumentationDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent
    let baseName = (name as NSString).deletingPathExtension.lowercased()
    let lowercasedName = name.lowercased()

    if let descriptor = Self.documentationFileDescriptors[lowercasedName] {
      return descriptor
    }
    if let descriptor = Self.documentationFileDescriptors[baseName] {
      return descriptor
    }
    if lowercasedName.hasPrefix("readme.") {
      return WorkspaceDocumentationDescriptor(category: "overview", source: "filename")
    }
    if lowercasedName.hasPrefix("changelog.") || lowercasedName.hasPrefix("changes.") {
      return WorkspaceDocumentationDescriptor(category: "changelog", source: "filename")
    }
    if lowercasedName.hasPrefix("license.") || lowercasedName.hasPrefix("licence.") {
      return WorkspaceDocumentationDescriptor(category: "license", source: "filename")
    }

    if isDocumentationDirectoryPath(workspaceRelativePath),
      isDocumentationFileExtension((name as NSString).pathExtension.lowercased())
    {
      return WorkspaceDocumentationDescriptor(
        category: "documentation", source: "documentation_directory")
    }

    return nil
  }

  internal func collectWorkspaceAgentFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    agentFiles: inout [WorkspaceAgentFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let info = try fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = agentFileDescriptor(for: info.workspaceRelativePath)
      {
        guard agentFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        agentFiles.append(
          WorkspaceAgentFileInfo(
            info: info,
            kind: descriptor.kind,
            source: descriptor.source
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        guard !Self.agentFileScanSkippedDirectoryNames.contains(name) else {
          continue
        }
        try collectWorkspaceAgentFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          agentFiles: &agentFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func agentFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceAgentFileDescriptor?
  {
    let normalized = workspaceRelativePath.replacingOccurrences(of: "\\", with: "/")
    let lowercasedPath = normalized.lowercased()
    let name = (normalized as NSString).lastPathComponent
    let lowercasedName = name.lowercased()

    if lowercasedName == "copilot-instructions.md" {
      guard
        lowercasedPath == ".github/copilot-instructions.md"
          || lowercasedPath.hasSuffix("/.github/copilot-instructions.md")
      else {
        return nil
      }
    }

    if let descriptor = Self.agentFileDescriptors[lowercasedName] {
      return descriptor
    }

    if lowercasedPath.hasPrefix(".cursor/rules/")
      || lowercasedPath.contains("/.cursor/rules/"),
      lowercasedName.hasSuffix(".md") || lowercasedName.hasSuffix(".mdc")
    {
      return WorkspaceAgentFileDescriptor(kind: "cursor_rule", source: "cursor_rules_directory")
    }

    if lowercasedPath.hasPrefix(".windsurf/rules/")
      || lowercasedPath.contains("/.windsurf/rules/"),
      lowercasedName.hasSuffix(".md")
    {
      return WorkspaceAgentFileDescriptor(
        kind: "windsurf_rule",
        source: "windsurf_rules_directory"
      )
    }

    if lowercasedName == "skill.md",
      lowercasedPath.hasPrefix("skills/") || lowercasedPath.contains("/skills/")
    {
      return WorkspaceAgentFileDescriptor(kind: "codex_skill", source: "skills_directory")
    }

    return nil
  }

  internal func collectWorkspaceInstructionFiles(
    directory: URL,
    scopeWorkspaceRelativePath: String,
    includeContent: Bool,
    maxBytesPerFile: Int,
    maxResults: Int,
    seenPaths: inout Set<String>,
    files: inout [WorkspaceInstructionFileInfo],
    resultTruncated: inout Bool,
    applyOrder: inout Int
  ) throws {
    for filename in Self.scopedInstructionFilenames {
      try appendWorkspaceInstructionFile(
        candidate: directory.appendingPathComponent(filename),
        scopeWorkspaceRelativePath: scopeWorkspaceRelativePath,
        includeContent: includeContent,
        maxBytesPerFile: maxBytesPerFile,
        maxResults: maxResults,
        seenPaths: &seenPaths,
        files: &files,
        resultTruncated: &resultTruncated,
        applyOrder: &applyOrder
      )
      guard !resultTruncated else {
        return
      }
    }

    try appendWorkspaceInstructionFile(
      candidate: directory.appendingPathComponent(".github/copilot-instructions.md"),
      scopeWorkspaceRelativePath: scopeWorkspaceRelativePath,
      includeContent: includeContent,
      maxBytesPerFile: maxBytesPerFile,
      maxResults: maxResults,
      seenPaths: &seenPaths,
      files: &files,
      resultTruncated: &resultTruncated,
      applyOrder: &applyOrder
    )
    guard !resultTruncated else {
      return
    }

    for ruleDirectoryPath in Self.scopedInstructionRuleDirectories {
      let ruleDirectory = directory.appendingPathComponent(ruleDirectoryPath)
      var isDirectory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: ruleDirectory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        continue
      }

      for child in try sortedDirectoryChildren(ruleDirectory, includeHidden: true) {
        try appendWorkspaceInstructionFile(
          candidate: child,
          scopeWorkspaceRelativePath: scopeWorkspaceRelativePath,
          includeContent: includeContent,
          maxBytesPerFile: maxBytesPerFile,
          maxResults: maxResults,
          seenPaths: &seenPaths,
          files: &files,
          resultTruncated: &resultTruncated,
          applyOrder: &applyOrder
        )
        guard !resultTruncated else {
          return
        }
      }
    }
  }

  private func appendWorkspaceInstructionFile(
    candidate: URL,
    scopeWorkspaceRelativePath: String,
    includeContent: Bool,
    maxBytesPerFile: Int,
    maxResults: Int,
    seenPaths: inout Set<String>,
    files: inout [WorkspaceInstructionFileInfo],
    resultTruncated: inout Bool,
    applyOrder: inout Int
  ) throws {
    guard !resultTruncated else {
      return
    }
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      return
    }

    let candidateWorkspaceRelativePath = workspaceRelativePathPreservingSymlinks(candidate)
    let resolved = try resolvedWorkspaceURL(candidateWorkspaceRelativePath)
    let info = try fileInfo(url: resolved)
    guard info.type == "file" else {
      return
    }
    guard seenPaths.insert(info.workspaceRelativePath).inserted else {
      return
    }
    guard
      let descriptor =
        agentFileDescriptor(for: candidateWorkspaceRelativePath)
        ?? agentFileDescriptor(for: info.workspaceRelativePath)
    else {
      return
    }
    guard files.count < maxResults else {
      resultTruncated = true
      return
    }

    let content =
      includeContent
      ? try readWorkspaceInstructionContent(url: resolved, maxBytes: maxBytesPerFile) : nil
    files.append(
      WorkspaceInstructionFileInfo(
        info: info,
        kind: descriptor.kind,
        source: descriptor.source,
        scopeWorkspaceRelativePath: scopeWorkspaceRelativePath,
        applyOrder: applyOrder,
        content: content
      ))
    applyOrder += 1
  }

  private func readWorkspaceInstructionContent(url: URL, maxBytes: Int) throws
    -> WorkspaceInstructionContent
  {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let limitedData = truncated ? Data(data.prefix(maxBytes)) : data
    let content = String(data: limitedData, encoding: .utf8)
    return WorkspaceInstructionContent(
      content: content,
      bytesRead: limitedData.count,
      truncated: truncated,
      validUTF8: content != nil
    )
  }

  private func isDocumentationDirectoryPath(_ workspaceRelativePath: String) -> Bool {
    workspaceRelativePath.split(separator: "/").dropLast().contains { component in
      let lowercased = component.lowercased()
      return lowercased == "docs"
        || lowercased == "doc"
        || lowercased == "documentation"
        || lowercased.hasSuffix(".docc")
    }
  }

  private func isDocumentationFileExtension(_ ext: String) -> Bool {
    ["md", "mdx", "txt", "rst", "adoc"].contains(ext)
  }

  internal func collectWorkspaceTestFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    testFiles: inout [WorkspaceTestFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let info = try fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = testFileDescriptor(for: info.workspaceRelativePath) {
        guard testFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        testFiles.append(
          WorkspaceTestFileInfo(
            info: info,
            language: descriptor.language,
            matchSource: descriptor.matchSource,
            style: descriptor.style
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceTestFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          testFiles: &testFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func testFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceTestFileDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    guard let language = Self.testFileExtensions[ext] else {
      return nil
    }

    let stem = (name as NSString).deletingPathExtension
    let lowercasedName = name.lowercased()
    let lowercasedStem = stem.lowercased()
    let components = workspaceRelativePath.split(separator: "/").dropLast().map {
      $0.lowercased()
    }

    if components.contains(where: { Self.testDirectoryNames.contains($0) }) {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "test_directory",
        style: "directory"
      )
    }

    if lowercasedName.contains(".test.") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "dot_test"
      )
    }
    if lowercasedName.contains(".spec.") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "dot_spec"
      )
    }
    if lowercasedStem.hasPrefix("test_") || lowercasedStem.hasPrefix("test-") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "test_prefix"
      )
    }
    if lowercasedStem.hasSuffix("_test") || lowercasedStem.hasSuffix("-test") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "test_suffix"
      )
    }
    if lowercasedStem.hasSuffix("_spec") || lowercasedStem.hasSuffix("-spec") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "spec_suffix"
      )
    }
    if stem.hasSuffix("Test") || stem.hasSuffix("Tests") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "camel_test_suffix"
      )
    }
    if stem.hasSuffix("Spec") || stem.hasSuffix("Specs") {
      return WorkspaceTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "camel_spec_suffix"
      )
    }

    return nil
  }

  internal func collectWorkspaceCIFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    ciFiles: inout [WorkspaceCIFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.ciSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = ciFileDescriptor(for: info.workspaceRelativePath) {
        guard ciFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        ciFiles.append(
          WorkspaceCIFileInfo(
            info: info,
            provider: descriptor.provider,
            category: descriptor.category,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceCIFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          ciFiles: &ciFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func ciFileDescriptor(for workspaceRelativePath: String) -> WorkspaceCIFileDescriptor? {
    let components = workspaceRelativePath.split(separator: "/").map { $0.lowercased() }
    let name = components.last ?? ""
    let ext = ((name as NSString).pathExtension).lowercased()

    if ciWorkflowPath(
      components, marker: ".github", folder: "workflows", extensions: Set(["yml", "yaml"]))
    {
      return WorkspaceCIFileDescriptor(
        provider: "github_actions",
        category: "workflow",
        matchSource: "workflow_directory"
      )
    }
    if ciWorkflowPath(
      components, marker: ".gitea", folder: "workflows", extensions: Set(["yml", "yaml"]))
    {
      return WorkspaceCIFileDescriptor(
        provider: "gitea_actions",
        category: "workflow",
        matchSource: "workflow_directory"
      )
    }
    if ciWorkflowPath(
      components, marker: ".forgejo", folder: "workflows", extensions: Set(["yml", "yaml"]))
    {
      return WorkspaceCIFileDescriptor(
        provider: "forgejo_actions",
        category: "workflow",
        matchSource: "workflow_directory"
      )
    }

    guard Self.ciFileExtensions.contains(ext) || name == "jenkinsfile" else {
      return nil
    }

    if name == ".gitlab-ci.yml" || name == ".gitlab-ci.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "gitlab_ci", category: "pipeline", matchSource: "filename")
    }
    if name == "jenkinsfile" {
      return WorkspaceCIFileDescriptor(
        provider: "jenkins", category: "pipeline", matchSource: "filename")
    }
    if name == "azure-pipelines.yml" || name == "azure-pipelines.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "azure_pipelines", category: "pipeline", matchSource: "filename")
    }
    if name == "bitrise.yml" || name == "bitrise.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "bitrise", category: "pipeline", matchSource: "filename")
    }
    if name == "appveyor.yml" || name == "appveyor.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "appveyor", category: "pipeline", matchSource: "filename")
    }
    if name == ".travis.yml" || name == ".travis.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "travis_ci", category: "pipeline", matchSource: "filename")
    }
    if name == ".drone.yml" || name == ".drone.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "drone", category: "pipeline", matchSource: "filename")
    }
    if name == ".woodpecker.yml" || name == ".woodpecker.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "woodpecker", category: "pipeline", matchSource: "filename")
    }
    if name == ".cirrus.yml" || name == ".cirrus.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "cirrus_ci", category: "pipeline", matchSource: "filename")
    }
    if name == "cloudbuild.yml" || name == "cloudbuild.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "google_cloud_build", category: "pipeline", matchSource: "filename")
    }
    if name == "buildspec.yml" || name == "buildspec.yaml" {
      return WorkspaceCIFileDescriptor(
        provider: "aws_codebuild", category: "pipeline", matchSource: "filename")
    }
    if name == "codemagic.yaml" || name == "codemagic.yml" {
      return WorkspaceCIFileDescriptor(
        provider: "codemagic", category: "pipeline", matchSource: "filename")
    }

    if components.count >= 2, components[components.count - 2] == ".circleci",
      name == "config.yml" || name == "config.yaml"
    {
      return WorkspaceCIFileDescriptor(
        provider: "circleci", category: "pipeline", matchSource: "config_directory")
    }
    if components.count >= 2, components[components.count - 2] == ".buildkite",
      ext == "yml" || ext == "yaml"
    {
      return WorkspaceCIFileDescriptor(
        provider: "buildkite", category: "pipeline", matchSource: "config_directory")
    }
    if components.count >= 2, components[components.count - 2] == ".semaphore",
      name == "semaphore.yml" || name == "semaphore.yaml"
    {
      return WorkspaceCIFileDescriptor(
        provider: "semaphore", category: "pipeline", matchSource: "config_directory")
    }

    return nil
  }

  private func ciWorkflowPath(
    _ components: [String],
    marker: String,
    folder: String,
    extensions: Set<String>
  ) -> Bool {
    guard components.count >= 3,
      let index = components.firstIndex(of: marker),
      index + 2 < components.count,
      components[index + 1] == folder
    else {
      return false
    }
    let name = components.last ?? ""
    return extensions.contains(((name as NSString).pathExtension).lowercased())
  }

  internal func collectWorkspaceInfraFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    infraFiles: inout [WorkspaceInfraFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.infraSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden,
        !Self.infraAlwaysIncludedDirectoryNames.contains(lowercasedName)
      {
        continue
      }

      if info.type == "file",
        let descriptor = infraFileDescriptor(for: info.workspaceRelativePath)
      {
        guard infraFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        infraFiles.append(
          WorkspaceInfraFileInfo(
            info: info,
            category: descriptor.category,
            provider: descriptor.provider,
            kind: descriptor.kind,
            format: descriptor.format,
            matchSource: descriptor.matchSource,
            jsonReadable: descriptor.jsonReadable,
            tomlReadable: descriptor.tomlReadable,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceInfraFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          infraFiles: &infraFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func infraFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceInfraFileDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent.lowercased()
    let ext = (workspaceRelativePath as NSString).pathExtension.lowercased()

    if var descriptor = Self.infraExactFileDescriptors[name] {
      descriptor.fileExtension = ext
      return descriptor
    }

    if var descriptor = infraFilenamePatternDescriptor(name: name, ext: ext) {
      descriptor.fileExtension = ext
      return descriptor
    }

    if var descriptor = Self.infraFileExtensions[ext] {
      descriptor.fileExtension = ext
      return descriptor
    }

    guard Self.directoryScopedInfraFileExtensions.contains(ext),
      isInInfraDirectory(workspaceRelativePath)
    else {
      return nil
    }

    var descriptor = directoryScopedInfraDescriptor(
      workspaceRelativePath: workspaceRelativePath,
      ext: ext
    )
    descriptor.fileExtension = ext
    return descriptor
  }

  private func infraFilenamePatternDescriptor(name: String, ext: String)
    -> WorkspaceInfraFileDescriptor?
  {
    if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
      return WorkspaceInfraFileDescriptor(
        category: "container",
        provider: "docker",
        kind: "image_build",
        format: "dockerfile",
        matchSource: "filename_pattern"
      )
    }
    if name.hasPrefix("containerfile.") || name.hasSuffix(".containerfile") {
      return WorkspaceInfraFileDescriptor(
        category: "container",
        provider: "containerfile",
        kind: "image_build",
        format: "containerfile",
        matchSource: "filename_pattern"
      )
    }
    if (ext == "yaml" || ext == "yml" || ext == "json") && name.contains("compose") {
      return WorkspaceInfraFileDescriptor(
        category: "container_orchestration",
        provider: "docker_compose",
        kind: "compose_file",
        format: ext == "json" ? "json" : "yaml",
        matchSource: "filename_pattern",
        jsonReadable: ext == "json"
      )
    }
    if name.hasSuffix(".tf.json") || name.hasSuffix(".tfvars.json") {
      return WorkspaceInfraFileDescriptor(
        category: "infrastructure_as_code",
        provider: "terraform",
        kind: name.hasSuffix(".tfvars.json") ? "variables" : "module",
        format: "json",
        matchSource: "filename_pattern",
        jsonReadable: true
      )
    }
    if name.hasSuffix(".pkr.hcl") {
      return WorkspaceInfraFileDescriptor(
        category: "infrastructure_as_code",
        provider: "packer",
        kind: "template",
        format: "hcl",
        matchSource: "filename_pattern"
      )
    }
    if name.hasSuffix(".nomad") || name.hasSuffix(".nomad.hcl") {
      return WorkspaceInfraFileDescriptor(
        category: "orchestration",
        provider: "nomad",
        kind: "job",
        format: ext == "hcl" ? "hcl" : "nomad",
        matchSource: "filename_pattern"
      )
    }

    return nil
  }

  private func directoryScopedInfraDescriptor(
    workspaceRelativePath: String,
    ext: String
  ) -> WorkspaceInfraFileDescriptor {
    let components = workspaceRelativePath.split(separator: "/").map { $0.lowercased() }
    let format = infraFormat(for: ext)

    if components.contains(".devcontainer") || components.contains("devcontainer") {
      return WorkspaceInfraFileDescriptor(
        category: "development_container",
        provider: "devcontainer",
        kind: "dev_environment",
        format: format,
        matchSource: "infra_directory",
        jsonReadable: ext == "json"
      )
    }
    if components.contains("helm") || components.contains("chart") || components.contains("charts")
    {
      return WorkspaceInfraFileDescriptor(
        category: "package_deployment",
        provider: "helm",
        kind: "chart_manifest",
        format: format,
        matchSource: "infra_directory",
        jsonReadable: ext == "json",
        tomlReadable: ext == "toml"
      )
    }
    if components.contains("k8s") || components.contains("kube")
      || components.contains("kubernetes") || components.contains("manifest")
      || components.contains("manifests")
    {
      return WorkspaceInfraFileDescriptor(
        category: "orchestration",
        provider: "kubernetes",
        kind: "manifest",
        format: format,
        matchSource: "infra_directory",
        jsonReadable: ext == "json"
      )
    }
    if components.contains("terraform") {
      return WorkspaceInfraFileDescriptor(
        category: "infrastructure_as_code",
        provider: "terraform",
        kind: "module",
        format: format,
        matchSource: "infra_directory",
        jsonReadable: ext == "json",
        tomlReadable: ext == "toml"
      )
    }

    return WorkspaceInfraFileDescriptor(
      category: "deployment",
      provider: "generic",
      kind: "deployment_manifest",
      format: format,
      matchSource: "infra_directory",
      jsonReadable: ext == "json",
      tomlReadable: ext == "toml"
    )
  }

  private func infraFormat(for ext: String) -> String {
    switch ext {
    case "yml", "yaml":
      return "yaml"
    case "json", "jsonc":
      return ext
    case "toml":
      return "toml"
    case "hcl":
      return "hcl"
    default:
      return ext
    }
  }

  private func isInInfraDirectory(_ workspaceRelativePath: String) -> Bool {
    let directory = (workspaceRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.infraDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectWorkspaceConfigFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    configFiles: inout [WorkspaceConfigFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.configSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = configFileDescriptor(for: info.workspaceRelativePath)
      {
        guard configFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        configFiles.append(
          WorkspaceConfigFileInfo(
            info: info,
            tool: descriptor.tool,
            category: descriptor.category,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceConfigFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          configFiles: &configFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func configFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceConfigFileDescriptor?
  {
    let components = workspaceRelativePath.split(separator: "/").map { $0.lowercased() }
    let name = components.last ?? ""

    if let descriptor = Self.configExactFileDescriptors[String(name)] {
      return descriptor
    }

    if components.count >= 2, components[components.count - 2] == ".vscode" {
      switch name {
      case "settings.json", "extensions.json", "tasks.json", "launch.json":
        return WorkspaceConfigFileDescriptor(
          tool: "vscode", category: "editor", matchSource: "config_directory")
      default:
        break
      }
    }

    if name.hasPrefix("tsconfig."), name.hasSuffix(".json") {
      return WorkspaceConfigFileDescriptor(
        tool: "typescript", category: "compiler", matchSource: "filename_pattern")
    }
    if name.hasPrefix("eslint.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "eslint", category: "linter", matchSource: "filename_pattern")
    }
    if name.hasPrefix("prettier.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "prettier", category: "formatter", matchSource: "filename_pattern")
    }
    if name.hasPrefix("stylelint.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "stylelint", category: "linter", matchSource: "filename_pattern")
    }
    if name.hasPrefix("babel.config."), configScriptOrJSONExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "babel", category: "transpiler", matchSource: "filename_pattern")
    }
    if name.hasPrefix(".babelrc."), configScriptOrJSONExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "babel", category: "transpiler", matchSource: "filename_pattern")
    }
    if name.hasPrefix("postcss.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "postcss", category: "css_processor", matchSource: "filename_pattern")
    }
    if name.hasPrefix("tailwind.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "tailwind", category: "styling", matchSource: "filename_pattern")
    }
    if name.hasPrefix("vite.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "vite", category: "build_tool", matchSource: "filename_pattern")
    }
    if name.hasPrefix("vitest.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "vitest", category: "test_runner", matchSource: "filename_pattern")
    }
    if name.hasPrefix("webpack.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "webpack", category: "build_tool", matchSource: "filename_pattern")
    }
    if name.hasPrefix("rollup.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "rollup", category: "build_tool", matchSource: "filename_pattern")
    }
    if name.hasPrefix("next.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "next", category: "framework", matchSource: "filename_pattern")
    }
    if name.hasPrefix("nuxt.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "nuxt", category: "framework", matchSource: "filename_pattern")
    }
    if name.hasPrefix("svelte.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "svelte", category: "framework", matchSource: "filename_pattern")
    }
    if name.hasPrefix("astro.config."), configScriptExtension(String(name)) {
      return WorkspaceConfigFileDescriptor(
        tool: "astro", category: "framework", matchSource: "filename_pattern")
    }
    if name == "turbo.json" {
      return WorkspaceConfigFileDescriptor(
        tool: "turbo", category: "monorepo", matchSource: "filename")
    }
    if name == "nx.json" {
      return WorkspaceConfigFileDescriptor(
        tool: "nx", category: "monorepo", matchSource: "filename")
    }

    return nil
  }

  private func configScriptExtension(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ["js", "cjs", "mjs", "ts", "cts", "mts"].contains(ext)
  }

  private func configScriptOrJSONExtension(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return configScriptExtension(name) || ext == "json" || ext == "jsonc"
  }

  internal func collectWorkspaceIgnoreFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    ignoreFiles: inout [WorkspaceIgnoreFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.configSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = ignoreFileDescriptor(for: info.workspaceRelativePath)
      {
        guard ignoreFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        ignoreFiles.append(
          WorkspaceIgnoreFileInfo(
            info: info,
            provider: descriptor.provider,
            category: descriptor.category,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceIgnoreFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          ignoreFiles: &ignoreFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func ignoreFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceIgnoreFileDescriptor?
  {
    let components = workspaceRelativePath.split(separator: "/").map { $0.lowercased() }
    if components.count >= 3,
      components[components.count - 3] == ".git",
      components[components.count - 2] == "info",
      components[components.count - 1] == "exclude"
    {
      return WorkspaceIgnoreFileDescriptor(
        provider: "git",
        category: "source_control_ignore",
        matchSource: "git_info_exclude"
      )
    }

    let name = components.last.map { String($0) } ?? ""
    return Self.ignoreFileDescriptors[name]
  }

  internal func collectWorkspaceAssetFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    assetFiles: inout [WorkspaceAssetFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = assetFileDescriptor(for: info.workspaceRelativePath)
      {
        guard assetFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        assetFiles.append(
          WorkspaceAssetFileInfo(
            info: info,
            category: descriptor.category,
            subtype: descriptor.subtype,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceAssetFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          assetFiles: &assetFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func assetFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceAssetFileDescriptor?
  {
    let ext = (workspaceRelativePath as NSString).pathExtension.lowercased()
    guard var descriptor = Self.assetFileExtensions[ext] else {
      return nil
    }
    descriptor.fileExtension = ext
    return descriptor
  }

  internal func collectWorkspaceArchiveFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    archiveFiles: inout [WorkspaceArchiveFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.archiveSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = archiveFileDescriptor(for: info.workspaceRelativePath)
      {
        guard archiveFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        archiveFiles.append(
          WorkspaceArchiveFileInfo(
            info: info,
            category: descriptor.category,
            format: descriptor.format,
            fileExtension: descriptor.fileExtension,
            listSupported: descriptor.listSupported
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceArchiveFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          archiveFiles: &archiveFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func archiveFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceArchiveFileDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent.lowercased()
    return Self.archiveFileDescriptors.first { name.hasSuffix($0.suffix) }
  }

  internal func collectWorkspaceLogFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    logFiles: inout [WorkspaceLogFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.logSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = logFileDescriptor(for: info.workspaceRelativePath)
      {
        guard logFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        logFiles.append(
          WorkspaceLogFileInfo(
            info: info,
            category: descriptor.category,
            kind: descriptor.kind,
            matchSource: descriptor.matchSource,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceLogFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          logFiles: &logFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func logFileDescriptor(for workspaceRelativePath: String) -> WorkspaceLogFileDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent.lowercased()
    if var descriptor = Self.logExactFileDescriptors[name] {
      descriptor.fileExtension = (workspaceRelativePath as NSString).pathExtension.lowercased()
      return descriptor
    }

    let ext = (workspaceRelativePath as NSString).pathExtension.lowercased()
    if var descriptor = Self.logFileExtensions[ext] {
      descriptor.fileExtension = ext
      return descriptor
    }

    if name.contains(".log.") || name.contains(".out.") || name.contains(".err.") {
      return WorkspaceLogFileDescriptor(
        category: "application_log",
        kind: "rotated",
        matchSource: "rotated_suffix",
        fileExtension: ext
      )
    }

    if isInLogDirectory(workspaceRelativePath),
      Self.logDirectoryFileExtensions.contains(ext)
    {
      return WorkspaceLogFileDescriptor(
        category: "application_log",
        kind: "log",
        matchSource: "logs_directory",
        fileExtension: ext
      )
    }

    return nil
  }

  private func isInLogDirectory(_ workspaceRelativePath: String) -> Bool {
    let directory = (workspaceRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.logDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectWorkspaceDataFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    dataFiles: inout [WorkspaceDataFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.dataSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = dataFileDescriptor(for: info.workspaceRelativePath)
      {
        guard dataFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        dataFiles.append(
          WorkspaceDataFileInfo(
            info: info,
            category: descriptor.category,
            format: descriptor.format,
            matchSource: descriptor.matchSource,
            textReadable: descriptor.textReadable,
            jsonReadable: descriptor.jsonReadable,
            jsonLinesReadable: descriptor.jsonLinesReadable,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceDataFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          dataFiles: &dataFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func dataFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceDataFileDescriptor?
  {
    let ext = (workspaceRelativePath as NSString).pathExtension.lowercased()
    if var descriptor = Self.dataFileExtensions[ext] {
      descriptor.fileExtension = ext
      return descriptor
    }

    guard Self.directoryScopedDataFileExtensions.contains(ext),
      isInDataDirectory(workspaceRelativePath),
      var descriptor = Self.directoryScopedDataFileDescriptors[ext]
    else {
      return nil
    }

    descriptor.fileExtension = ext
    return descriptor
  }

  private func isInDataDirectory(_ workspaceRelativePath: String) -> Bool {
    let directory = (workspaceRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.dataDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectWorkspaceSchemaFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    schemaFiles: inout [WorkspaceSchemaFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.schemaSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = schemaFileDescriptor(for: info.workspaceRelativePath)
      {
        guard schemaFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        schemaFiles.append(
          WorkspaceSchemaFileInfo(
            info: info,
            category: descriptor.category,
            schemaKind: descriptor.schemaKind,
            format: descriptor.format,
            matchSource: descriptor.matchSource,
            jsonReadable: descriptor.jsonReadable,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceSchemaFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          schemaFiles: &schemaFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func schemaFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceSchemaFileDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent.lowercased()
    let ext = (workspaceRelativePath as NSString).pathExtension.lowercased()

    if var descriptor = Self.schemaExactFileDescriptors[name] {
      descriptor.fileExtension = ext
      return descriptor
    }

    if var descriptor = schemaFilenamePatternDescriptor(name: name, ext: ext) {
      descriptor.fileExtension = ext
      return descriptor
    }

    if var descriptor = Self.schemaFileExtensions[ext] {
      descriptor.fileExtension = ext
      return descriptor
    }

    guard Self.directoryScopedSchemaFileExtensions.contains(ext),
      isInSchemaDirectory(workspaceRelativePath)
    else {
      return nil
    }

    var descriptor = directoryScopedSchemaDescriptor(ext: ext)
    descriptor.fileExtension = ext
    return descriptor
  }

  private func schemaFilenamePatternDescriptor(name: String, ext: String)
    -> WorkspaceSchemaFileDescriptor?
  {
    guard ["json", "yaml", "yml"].contains(ext) else {
      return nil
    }

    if name.contains("openapi") {
      return WorkspaceSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "openapi",
        format: ext == "json" ? "json" : "yaml",
        jsonReadable: ext == "json",
        matchSource: "filename_pattern"
      )
    }
    if name.contains("swagger") {
      return WorkspaceSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "swagger",
        format: ext == "json" ? "json" : "yaml",
        jsonReadable: ext == "json",
        matchSource: "filename_pattern"
      )
    }
    if name.contains("asyncapi") {
      return WorkspaceSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "asyncapi",
        format: ext == "json" ? "json" : "yaml",
        jsonReadable: ext == "json",
        matchSource: "filename_pattern"
      )
    }
    if name.hasSuffix(".schema.json") {
      return WorkspaceSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "json_schema",
        format: "json",
        jsonReadable: true,
        matchSource: "filename_pattern"
      )
    }

    return nil
  }

  private func directoryScopedSchemaDescriptor(ext: String) -> WorkspaceSchemaFileDescriptor {
    switch ext {
    case "json":
      return WorkspaceSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "json_schema",
        format: "json",
        jsonReadable: true,
        matchSource: "schema_directory"
      )
    case "json5":
      return WorkspaceSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "json_schema",
        format: "json5",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    case "sql":
      return WorkspaceSchemaFileDescriptor(
        category: "database_schema",
        schemaKind: "sql_migration",
        format: "sql",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    case "xml":
      return WorkspaceSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "xml_schema",
        format: "xml",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    case "toml":
      return WorkspaceSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "schema_definition",
        format: "toml",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    default:
      return WorkspaceSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "schema_definition",
        format: "yaml",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    }
  }

  private func isInSchemaDirectory(_ workspaceRelativePath: String) -> Bool {
    let directory = (workspaceRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.schemaDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectWorkspaceSourceFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    includeTests: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    sourceFiles: inout [WorkspaceSourceFileInfo],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = sourceFileDescriptor(for: info.workspaceRelativePath),
        includeTests || testFileDescriptor(for: info.workspaceRelativePath) == nil
      {
        guard sourceFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        sourceFiles.append(
          WorkspaceSourceFileInfo(
            info: info,
            language: descriptor.language,
            kind: descriptor.kind,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceSourceFiles(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          includeTests: includeTests,
          maxResults: maxResults,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          sourceFiles: &sourceFiles,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func collectWorkspaceOutlineItems(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    includeTests: Bool,
    includeImports: Bool,
    maxFiles: Int,
    maxItems: Int,
    maxBytesPerFile: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    outlineFileCount: inout Int,
    bytesScanned: inout Int,
    fileTruncatedCount: inout Int,
    invalidUTF8FileCount: inout Int,
    items: inout [WorkspaceOutlineItem],
    scanTruncated: inout Bool,
    resultTruncated: inout Bool
  ) throws {
    guard !scanTruncated, !resultTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated, !resultTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file" {
        try appendWorkspaceOutlineItems(
          url: child,
          info: info,
          includeTests: includeTests,
          includeImports: includeImports,
          maxFiles: maxFiles,
          maxItems: maxItems,
          maxBytesPerFile: maxBytesPerFile,
          outlineFileCount: &outlineFileCount,
          bytesScanned: &bytesScanned,
          fileTruncatedCount: &fileTruncatedCount,
          invalidUTF8FileCount: &invalidUTF8FileCount,
          items: &items,
          resultTruncated: &resultTruncated
        )
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceOutlineItems(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          includeTests: includeTests,
          includeImports: includeImports,
          maxFiles: maxFiles,
          maxItems: maxItems,
          maxBytesPerFile: maxBytesPerFile,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          outlineFileCount: &outlineFileCount,
          bytesScanned: &bytesScanned,
          fileTruncatedCount: &fileTruncatedCount,
          invalidUTF8FileCount: &invalidUTF8FileCount,
          items: &items,
          scanTruncated: &scanTruncated,
          resultTruncated: &resultTruncated
        )
      }
    }
  }

  internal func appendWorkspaceOutlineItems(
    url: URL,
    info: FileInfo,
    includeTests: Bool,
    includeImports: Bool,
    maxFiles: Int,
    maxItems: Int,
    maxBytesPerFile: Int,
    outlineFileCount: inout Int,
    bytesScanned: inout Int,
    fileTruncatedCount: inout Int,
    invalidUTF8FileCount: inout Int,
    items: inout [WorkspaceOutlineItem],
    resultTruncated: inout Bool
  ) throws {
    guard !resultTruncated else {
      return
    }
    guard info.type == "file", let language = outlineLanguage(for: url) else {
      return
    }
    guard includeTests || testFileDescriptor(for: info.workspaceRelativePath) == nil else {
      return
    }
    guard outlineFileCount < maxFiles else {
      resultTruncated = true
      return
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let fileTruncated = data.count > maxBytesPerFile
    let contentData = fileTruncated ? Data(data.prefix(maxBytesPerFile)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      invalidUTF8FileCount += 1
      return
    }

    outlineFileCount += 1
    bytesScanned += contentData.count
    if fileTruncated {
      fileTruncatedCount += 1
    }

    for item in outlineItems(in: content, language: language, includeImports: includeImports) {
      guard items.count < maxItems else {
        resultTruncated = true
        return
      }
      items.append(
        WorkspaceOutlineItem(
          info: info,
          language: language,
          item: item,
          fileTruncated: fileTruncated
        ))
    }
  }

  internal func sourceFileDescriptor(for workspaceRelativePath: String)
    -> WorkspaceSourceFileDescriptor?
  {
    let name = (workspaceRelativePath as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    guard let descriptor = Self.sourceFileExtensions[ext] else {
      return nil
    }
    return descriptor
  }

  internal func collectWorkspaceCommandManifests(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    manifests: inout [FileInfo],
    scanTruncated: inout Bool
  ) throws {
    guard !scanTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: true) {
      guard !scanTruncated else {
        return
      }
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let name = child.lastPathComponent
      let lowercasedName = name.lowercased()
      let info = try fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", Self.commandManifestNames.contains(name) {
        manifests.append(info)
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectWorkspaceCommandManifests(
          directory: child,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          manifests: &manifests,
          scanTruncated: &scanTruncated
        )
      }
    }
  }

  internal func parseWorkspaceCommandManifest(
    info: FileInfo,
    maxBytesPerFile: Int
  ) -> WorkspaceCommandManifestParseResult {
    let url = URL(fileURLWithPath: info.path)
    let name = url.lastPathComponent
    let cwd = (info.workspaceRelativePath as NSString).deletingLastPathComponent
    let normalizedCWD = cwd == "." ? "" : cwd
    let readResult: WorkspaceCommandManifestReadResult
    do {
      readResult = try readWorkspaceCommandManifest(url: url, maxBytesPerFile: maxBytesPerFile)
    } catch {
      return WorkspaceCommandManifestParseResult(
        commands: [],
        errors: [
          WorkspaceCommandParseError(
            sourceWorkspaceRelativePath: info.workspaceRelativePath,
            message: error.localizedDescription)
        ],
        fileTruncated: false
      )
    }

    if let parseError = readResult.parseError {
      return WorkspaceCommandManifestParseResult(
        commands: [],
        errors: [
          WorkspaceCommandParseError(
            sourceWorkspaceRelativePath: info.workspaceRelativePath,
            message: parseError)
        ],
        fileTruncated: readResult.fileTruncated
      )
    }

    switch name {
    case "package.json":
      return parsePackageJSONCommands(
        content: readResult.content,
        info: info,
        cwdWorkspaceRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated
      )
    case "Package.swift":
      return WorkspaceCommandManifestParseResult(
        commands: swiftPackageCommands(info: info, cwdWorkspaceRelativePath: normalizedCWD),
        errors: [],
        fileTruncated: readResult.fileTruncated
      )
    case "Cargo.toml":
      return parseCargoCommands(
        content: readResult.content,
        info: info,
        cwdWorkspaceRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated
      )
    case "go.mod":
      return parseGoModCommands(
        content: readResult.content,
        info: info,
        cwdWorkspaceRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated
      )
    case "Makefile", "makefile", "GNUmakefile":
      return parseMakefileCommands(
        content: readResult.content,
        info: info,
        cwdWorkspaceRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated,
        executable: "make"
      )
    case "Justfile", "justfile":
      return parseMakefileCommands(
        content: readResult.content,
        info: info,
        cwdWorkspaceRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated,
        executable: "just"
      )
    default:
      return WorkspaceCommandManifestParseResult(
        commands: [],
        errors: [],
        fileTruncated: readResult.fileTruncated
      )
    }
  }

  private func readWorkspaceCommandManifest(
    url: URL,
    maxBytesPerFile: Int
  ) throws -> WorkspaceCommandManifestReadResult {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let fileTruncated = data.count > maxBytesPerFile
    let limitedData = fileTruncated ? Data(data.prefix(maxBytesPerFile)) : data
    guard !limitedData.contains(0) else {
      return WorkspaceCommandManifestReadResult(
        content: "",
        fileTruncated: fileTruncated,
        parseError: "File appears to be binary."
      )
    }
    guard let content = String(data: limitedData, encoding: .utf8) else {
      return WorkspaceCommandManifestReadResult(
        content: "",
        fileTruncated: fileTruncated,
        parseError: "File is not valid UTF-8."
      )
    }
    return WorkspaceCommandManifestReadResult(
      content: content,
      fileTruncated: fileTruncated,
      parseError: nil
    )
  }

  private func parsePackageJSONCommands(
    content: String,
    info: FileInfo,
    cwdWorkspaceRelativePath: String,
    fileTruncated: Bool
  ) -> WorkspaceCommandManifestParseResult {
    let data = Data(content.utf8)
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      return WorkspaceCommandManifestParseResult(
        commands: [],
        errors: [
          WorkspaceCommandParseError(
            sourceWorkspaceRelativePath: info.workspaceRelativePath,
            message: "Unable to parse package.json: \(error.localizedDescription)")
        ],
        fileTruncated: fileTruncated
      )
    }

    guard let object = value.objectValue else {
      return WorkspaceCommandManifestParseResult(
        commands: [],
        errors: [
          WorkspaceCommandParseError(
            sourceWorkspaceRelativePath: info.workspaceRelativePath,
            message: "package.json root is not an object.")
        ],
        fileTruncated: fileTruncated
      )
    }

    let packageManager = nodePackageManager(
      packageManagerField: object["packageManager"]?.stringValue,
      cwdWorkspaceRelativePath: cwdWorkspaceRelativePath
    )
    let scripts = object["scripts"]?.objectValue ?? [:]
    let commands = scripts.keys.sorted().compactMap { scriptName -> WorkspaceCommandInfo? in
      guard let definition = scripts[scriptName]?.stringValue else {
        return nil
      }
      return commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "node",
        kind: "package_script",
        name: scriptName,
        definition: definition,
        definitionSource: "package.json:scripts",
        suggestedCLIID: packageManager,
        requiredExecutable: packageManager,
        argv: ["run", scriptName],
        fileTruncated: fileTruncated
      )
    }

    return WorkspaceCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func nodePackageManager(
    packageManagerField: String?,
    cwdWorkspaceRelativePath: String
  ) -> String {
    if let packageManagerField {
      if packageManagerField.hasPrefix("pnpm@") {
        return "pnpm"
      }
      if packageManagerField.hasPrefix("yarn@") {
        return "yarn"
      }
      if packageManagerField.hasPrefix("bun@") {
        return "bun"
      }
      if packageManagerField.hasPrefix("npm@") {
        return "npm"
      }
    }

    let directory = workspaceURL(forRelativeDirectory: cwdWorkspaceRelativePath)
    if FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("pnpm-lock.yaml").path)
    {
      return "pnpm"
    }
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) {
      return "yarn"
    }
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("bun.lock").path)
      || FileManager.default.fileExists(atPath: directory.appendingPathComponent("bun.lockb").path)
    {
      return "bun"
    }
    return "npm"
  }

  private func swiftPackageCommands(
    info: FileInfo,
    cwdWorkspaceRelativePath: String
  ) -> [WorkspaceCommandInfo] {
    [
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "swift",
        kind: "standard_command",
        name: "build",
        definition: nil,
        definitionSource: "swiftpm",
        suggestedCLIID: "swift",
        requiredExecutable: "swift",
        argv: ["build"],
        fileTruncated: false
      ),
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "swift",
        kind: "standard_command",
        name: "test",
        definition: nil,
        definitionSource: "swiftpm",
        suggestedCLIID: "swift",
        requiredExecutable: "swift",
        argv: ["test"],
        fileTruncated: false
      ),
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "swift",
        kind: "standard_command",
        name: "describe",
        definition: nil,
        definitionSource: "swiftpm",
        suggestedCLIID: "swift",
        requiredExecutable: "swift",
        argv: ["package", "describe", "--type", "json"],
        fileTruncated: false
      ),
    ]
  }

  private func parseCargoCommands(
    content: String,
    info: FileInfo,
    cwdWorkspaceRelativePath: String,
    fileTruncated: Bool
  ) -> WorkspaceCommandManifestParseResult {
    let hasMain = FileManager.default.fileExists(
      atPath: workspaceURL(forRelativeDirectory: cwdWorkspaceRelativePath)
        .appendingPathComponent("src/main.rs").path)
    var commands = [
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "rust",
        kind: "standard_command",
        name: "build",
        definition: nil,
        definitionSource: "cargo",
        suggestedCLIID: "cargo",
        requiredExecutable: "cargo",
        argv: ["build"],
        fileTruncated: fileTruncated
      ),
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "rust",
        kind: "standard_command",
        name: "test",
        definition: nil,
        definitionSource: "cargo",
        suggestedCLIID: "cargo",
        requiredExecutable: "cargo",
        argv: ["test"],
        fileTruncated: fileTruncated
      ),
    ]
    if hasMain || content.contains("[[bin]]") {
      commands.append(
        commandInfo(
          source: info,
          cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
          ecosystem: "rust",
          kind: "standard_command",
          name: "run",
          definition: nil,
          definitionSource: "cargo",
          suggestedCLIID: "cargo",
          requiredExecutable: "cargo",
          argv: ["run"],
          fileTruncated: fileTruncated
        ))
    }
    return WorkspaceCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func parseGoModCommands(
    content: String,
    info: FileInfo,
    cwdWorkspaceRelativePath: String,
    fileTruncated: Bool
  ) -> WorkspaceCommandManifestParseResult {
    let moduleName = content.split(separator: "\n", omittingEmptySubsequences: false)
      .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("module ") }
      .map { line in
        String(line.trimmingCharacters(in: .whitespaces).dropFirst("module ".count))
      }

    let commands = [
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "go",
        kind: "standard_command",
        name: "test",
        definition: moduleName,
        definitionSource: "go.mod:module",
        suggestedCLIID: "go",
        requiredExecutable: "go",
        argv: ["test", "./..."],
        fileTruncated: fileTruncated
      ),
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "go",
        kind: "standard_command",
        name: "build",
        definition: moduleName,
        definitionSource: "go.mod:module",
        suggestedCLIID: "go",
        requiredExecutable: "go",
        argv: ["build", "./..."],
        fileTruncated: fileTruncated
      ),
      commandInfo(
        source: info,
        cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
        ecosystem: "go",
        kind: "standard_command",
        name: "list",
        definition: moduleName,
        definitionSource: "go.mod:module",
        suggestedCLIID: "go",
        requiredExecutable: "go",
        argv: ["list", "./..."],
        fileTruncated: fileTruncated
      ),
    ]

    return WorkspaceCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func parseMakefileCommands(
    content: String,
    info: FileInfo,
    cwdWorkspaceRelativePath: String,
    fileTruncated: Bool,
    executable: String
  ) -> WorkspaceCommandManifestParseResult {
    var commands: [WorkspaceCommandInfo] = []
    var seen = Set<String>()
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      guard let targets = makefileTargets(in: line) else {
        continue
      }
      for target in targets where seen.insert(target).inserted {
        commands.append(
          commandInfo(
            source: info,
            cwdWorkspaceRelativePath: cwdWorkspaceRelativePath,
            ecosystem: executable == "just" ? "just" : "make",
            kind: "target",
            name: target,
            definition: nil,
            definitionSource: "\(info.workspaceRelativePath):target",
            suggestedCLIID: executable,
            requiredExecutable: executable,
            argv: [target],
            fileTruncated: fileTruncated
          ))
      }
    }

    return WorkspaceCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func makefileTargets(in line: String) -> [String]? {
    guard !line.isEmpty, !line.hasPrefix("\t"), !line.hasPrefix(" ") else {
      return nil
    }
    guard let colon = line.firstIndex(of: ":") else {
      return nil
    }
    let left = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    guard !left.isEmpty, !left.hasPrefix("."), !left.contains("="), !left.contains("%") else {
      return nil
    }
    let afterColon = line[line.index(after: colon)...]
    if afterColon.first == "=" {
      return nil
    }

    let targets = left.split(whereSeparator: { $0 == " " || $0 == "\t" })
      .map(String.init)
      .filter(isMakefileTargetName)
    return targets.isEmpty ? nil : targets
  }

  private func isMakefileTargetName(_ name: String) -> Bool {
    guard !name.isEmpty else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      (scalar.value >= 48 && scalar.value <= 57)
        || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
        || scalar.value == 45
        || scalar.value == 46
        || scalar.value == 47
        || scalar.value == 95
    }
  }

  private func commandInfo(
    source: FileInfo,
    cwdWorkspaceRelativePath: String,
    ecosystem: String,
    kind: String,
    name: String,
    definition: String?,
    definitionSource: String,
    suggestedCLIID: String,
    requiredExecutable: String,
    argv: [String],
    fileTruncated: Bool
  ) -> WorkspaceCommandInfo {
    WorkspaceCommandInfo(
      sourcePath: source.path,
      sourceWorkspaceRelativePath: source.workspaceRelativePath,
      cwdWorkspaceRelativePath: cwdWorkspaceRelativePath.isEmpty ? "." : cwdWorkspaceRelativePath,
      ecosystem: ecosystem,
      kind: kind,
      name: name,
      definition: definition.map { limitedCommandDefinition($0) },
      definitionTruncated: definition.map { $0 != limitedCommandDefinition($0) } ?? false,
      definitionSource: definitionSource,
      executorTool: "cli.exec",
      suggestedCLIID: suggestedCLIID,
      registeredCLIProvider: configuration.cli.commands.contains { $0.id == suggestedCLIID },
      requiredExecutable: requiredExecutable,
      argv: argv,
      fileTruncated: fileTruncated
    )
  }

  private func limitedCommandDefinition(_ value: String) -> String {
    String(value.prefix(500))
  }

  internal func validateTodoMarkers(_ markers: [String]) throws {
    guard !markers.isEmpty else {
      throw GatewayToolError.invalidArguments("markers must not be empty.")
    }
    guard markers.count <= 20 else {
      throw GatewayToolError.invalidArguments("markers must contain at most 20 values.")
    }

    for marker in markers {
      guard !marker.isEmpty else {
        throw GatewayToolError.invalidArguments("markers must not contain empty strings.")
      }
      guard marker.utf8.count <= 64 else {
        throw GatewayToolError.invalidArguments("markers must be 64 bytes or fewer.")
      }
      guard
        marker.unicodeScalars.allSatisfy({ scalar in
          !((scalar.value <= 0x1F) || (scalar.value >= 0x7F && scalar.value <= 0x9F))
        })
      else {
        throw GatewayToolError.invalidArguments("markers must not contain control characters.")
      }
    }
  }
}

internal struct WorkspaceOutlineItem {
  var info: FileInfo
  var language: String
  var item: FileOutlineItem
  var fileTruncated: Bool

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "language": .string(language),
      "line": .integer(Int64(item.line)),
      "kind": .string(item.kind),
      "level": item.level.map { .integer(Int64($0)) } ?? .null,
      "name": .string(item.name),
      "text": .string(item.text),
      "file_truncated": .bool(fileTruncated),
      "read_context": .object([
        "tool": .string("file.read_context"),
        "path": .string(info.workspaceRelativePath),
        "line": .integer(Int64(item.line)),
      ]),
      "outline_context": .object([
        "tool": .string("file.outline"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ])
  }
}

internal struct WorkspaceDirectoryStatInfo {
  var workspaceRelativePath: String
  var name: String
  var fileCount = 0
  var directoryCount = 0
  var symlinkCount = 0
  var totalSizeBytes: Int64 = 0
  var sourceFileCount = 0
  var testFileCount = 0
  var dependencyFileCount = 0
  var documentationFileCount = 0
  var ciFileCount = 0
  var configFileCount = 0
  var executableFileCount = 0
  var skippedSubtreeCount = 0

  mutating func record(info: FileInfo) {
    if info.isSymlink {
      symlinkCount += 1
      return
    }
    switch info.type {
    case "directory":
      directoryCount += 1
    case "file":
      fileCount += 1
      totalSizeBytes += info.size ?? 0
    default:
      break
    }
  }

  var json: JSONValue {
    .object([
      "workspace_relative_path": .string(workspaceRelativePath),
      "name": .string(name),
      "file_count": .integer(Int64(fileCount)),
      "directory_count": .integer(Int64(directoryCount)),
      "symlink_count": .integer(Int64(symlinkCount)),
      "total_size_bytes": .integer(Int64(totalSizeBytes)),
      "source_file_count": .integer(Int64(sourceFileCount)),
      "test_file_count": .integer(Int64(testFileCount)),
      "dependency_file_count": .integer(Int64(dependencyFileCount)),
      "documentation_file_count": .integer(Int64(documentationFileCount)),
      "ci_file_count": .integer(Int64(ciFileCount)),
      "config_file_count": .integer(Int64(configFileCount)),
      "executable_file_count": .integer(Int64(executableFileCount)),
      "skipped_subtree_count": .integer(Int64(skippedSubtreeCount)),
    ])
  }
}

private struct WorkspaceArtifactDirectoryDescriptor {
  var category: String
  var kind: String
  var cleanupRisk: String
}

internal struct WorkspaceArtifactDirectoryInfo {
  var info: FileInfo
  var category: String
  var kind: String
  var cleanupRisk: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "category": .string(category),
      "kind": .string(kind),
      "cleanup_risk": .string(cleanupRisk),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "created_at": info.createdAt.map { .string(iso8601String($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "is_readable": .bool(info.isReadable),
      "is_writable": .bool(info.isWritable),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "disk_usage_context": .object([
        "tool": .string("file.disk_usage"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "tree_context": .object([
        "tool": .string("file.tree"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "directory_stats_context": .object([
        "tool": .string("workspace.directory_stats"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ])
  }
}

internal struct WorkspaceEmptyDirectoryInfo {
  var path: String
  var workspaceRelativePath: String
  var name: String
  var depth: Int
  var isRoot: Bool
  var modifiedAt: Date?

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "name": .string(name),
      "depth": .integer(Int64(depth)),
      "is_root": .bool(isRoot),
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "child_count": .number(0),
      "workspace.reveal": .object([
        "tool": .string("workspace.reveal"),
        "arguments": .object([
          "path": .string(workspaceRelativePath)
        ]),
      ]),
    ])
  }
}

internal struct WorkspaceGitChange {
  var indexStatus: String
  var worktreeStatus: String
  var path: String
  var originalPath: String?

  var status: String {
    indexStatus + worktreeStatus
  }

  var json: JSONValue {
    .object([
      "status": .string(status),
      "index_status": .string(indexStatus),
      "worktree_status": .string(worktreeStatus),
      "path": .string(path),
      "workspace_relative_path": .string(path),
      "original_path": originalPath.map(JSONValue.string) ?? .null,
    ])
  }
}

internal struct WorkspaceFileTypeSummary {
  var extensionName: String
  var displayName: String
  var fileCount: Int
  var sizeBytes: Int64

  var json: JSONValue {
    .object([
      "extension": .string(extensionName),
      "display": .string(displayName),
      "file_count": .integer(Int64(fileCount)),
      "size_bytes": .integer(Int64(sizeBytes)),
    ])
  }
}

internal struct WorkspaceSymlinkInfo {
  var path: String
  var workspaceRelativePath: String
  var destination: String
  var targetAbsolutePath: String
  var targetExists: Bool
  var targetIsDirectory: Bool
  var targetWorkspaceContained: Bool

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "destination": .string(destination),
      "target_absolute_path": .string(targetAbsolutePath),
      "target_exists": .bool(targetExists),
      "target_is_directory": .bool(targetIsDirectory),
      "target_workspace_contained": .bool(targetWorkspaceContained),
      "broken": .bool(!targetExists),
    ])
  }
}

internal struct WorkspaceTodoMatch {
  var marker: String
  var path: String
  var workspaceRelativePath: String
  var line: Int
  var column: Int
  var preview: String
  var fileTruncated: Bool

  var json: JSONValue {
    .object([
      "marker": .string(marker),
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "line": .integer(Int64(line)),
      "column": .integer(Int64(column)),
      "preview": .string(preview),
      "file_truncated": .bool(fileTruncated),
    ])
  }
}

internal struct WorkspaceEnvFileInfo {
  var path: String
  var workspaceRelativePath: String
  var sizeBytes: Int64?
  var modifiedAt: Date?
  var bytesScanned: Int
  var fileTruncated: Bool
  var keysTruncated: Bool
  var invalidLineCount: Int
  var parseError: String?
  var keys: [WorkspaceEnvKeyInfo]

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "size_bytes": sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "bytes_scanned": .integer(Int64(bytesScanned)),
      "file_truncated": .bool(fileTruncated),
      "keys_truncated": .bool(keysTruncated),
      "invalid_line_count": .integer(Int64(invalidLineCount)),
      "parse_error": parseError.map(JSONValue.string) ?? .null,
      "key_count": .integer(Int64(keys.count)),
      "distinct_key_count": .integer(Int64(Set(keys.map(\.name)).count)),
      "values_redacted": .bool(true),
      "keys": .array(keys.map(\.json)),
    ])
  }
}

internal struct WorkspaceEnvKeyInfo {
  var name: String
  var line: Int
  var exported: Bool
  var hasValue: Bool
  var valueEmpty: Bool

  var json: JSONValue {
    .object([
      "name": .string(name),
      "line": .integer(Int64(line)),
      "exported": .bool(exported),
      "has_value": .bool(hasValue),
      "value_empty": .bool(valueEmpty),
    ])
  }
}

private enum ParsedEnvLine {
  case invalid
  case key(WorkspaceEnvKeyInfo)
}

internal struct WorkspaceDependencyFileDescriptor {
  var name: String
  var ecosystem: String
  var role: String
}

internal struct WorkspaceDependencyFileInfo {
  var info: FileInfo
  var ecosystem: String
  var role: String

  var xmlReadable: Bool {
    ((info.workspaceRelativePath as NSString).lastPathComponent).lowercased().hasSuffix(".xml")
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "ecosystem": .string(ecosystem),
      "role": .string(role),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "xml_readable": .bool(xmlReadable),
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct WorkspaceProjectDependencyFileInfo {
  var workspaceRelativePath: String
  var name: String
  var ecosystem: String
  var role: String

  var json: JSONValue {
    .object([
      "workspace_relative_path": .string(workspaceRelativePath),
      "name": .string(name),
      "ecosystem": .string(ecosystem),
      "role": .string(role),
    ])
  }
}

internal struct WorkspaceProjectRootInfo {
  var path: String
  var workspaceRelativePath: String
  var ecosystems: [String]
  var manifestFiles: [String]
  var lockFiles: [String]
  var checksumFiles: [String]
  var dependencyFiles: [WorkspaceProjectDependencyFileInfo]
  var isWorkspaceRoot: Bool

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "ecosystems": .array(ecosystems.map(JSONValue.string)),
      "manifest_files": .array(manifestFiles.map(JSONValue.string)),
      "lock_files": .array(lockFiles.map(JSONValue.string)),
      "checksum_files": .array(checksumFiles.map(JSONValue.string)),
      "dependency_file_count": .integer(Int64(dependencyFiles.count)),
      "dependency_files": .array(dependencyFiles.map(\.json)),
      "is_workspace_root": .bool(isWorkspaceRoot),
    ])
  }
}

internal struct WorkspaceDocumentationDescriptor {
  var category: String
  var source: String
}

internal struct WorkspaceDocumentationFileInfo {
  var info: FileInfo
  var category: String
  var source: String

  var isMarkdown: Bool {
    let ext = (info.workspaceRelativePath as NSString).pathExtension.lowercased()
    return ["md", "markdown", "mdown", "mdx"].contains(ext)
      || (info.workspaceRelativePath as NSString).lastPathComponent.lowercased() == "readme"
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "category": .string(category),
      "source": .string(source),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "markdown_links_context": isMarkdown
        ? .object([
          "tool": .string("markdown.links"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "markdown_link_check_context": isMarkdown
        ? .object([
          "tool": .string("markdown.link_check"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct WorkspaceAgentFileDescriptor {
  var kind: String
  var source: String
}

internal struct WorkspaceAgentFileInfo {
  var info: FileInfo
  var kind: String
  var source: String

  var scopeWorkspaceRelativePath: String {
    let directory = (info.workspaceRelativePath as NSString).deletingLastPathComponent
    return directory.isEmpty ? "." : directory
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "kind": .string(kind),
      "source": .string(source),
      "scope_workspace_relative_path": .string(scopeWorkspaceRelativePath),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "read_context": .object([
        "tool": .string("file.read"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ])
  }
}

internal struct WorkspaceInstructionContent {
  var content: String?
  var bytesRead: Int
  var truncated: Bool
  var validUTF8: Bool
}

internal struct WorkspaceInstructionFileInfo {
  var info: FileInfo
  var kind: String
  var source: String
  var scopeWorkspaceRelativePath: String
  var applyOrder: Int
  var content: WorkspaceInstructionContent?

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "kind": .string(kind),
      "source": .string(source),
      "scope_workspace_relative_path": .string(scopeWorkspaceRelativePath),
      "apply_order": .integer(Int64(applyOrder)),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "content_included": .bool(content != nil),
      "content": content?.content.map(JSONValue.string) ?? .null,
      "content_bytes_read": content.map { .integer(Int64($0.bytesRead)) } ?? .null,
      "content_truncated": content.map { .bool($0.truncated) } ?? .null,
      "valid_utf8": content.map { .bool($0.validUTF8) } ?? .null,
      "read_context": .object([
        "tool": .string("file.read"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ])
  }
}

internal struct WorkspaceTestFileDescriptor {
  var language: String
  var matchSource: String
  var style: String
}

internal struct WorkspaceTestFileInfo {
  var info: FileInfo
  var language: String
  var matchSource: String
  var style: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "language": .string(language),
      "match_source": .string(matchSource),
      "style": .string(style),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
    ])
  }
}

internal struct WorkspaceCIFileDescriptor {
  var provider: String
  var category: String
  var matchSource: String
}

internal struct WorkspaceCIFileInfo {
  var info: FileInfo
  var provider: String
  var category: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "provider": .string(provider),
      "category": .string(category),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
    ])
  }
}

internal struct WorkspaceInfraFileDescriptor {
  var category: String
  var provider: String
  var kind: String
  var format: String
  var matchSource: String
  var jsonReadable: Bool = false
  var tomlReadable: Bool = false
  var fileExtension: String = ""
}

internal struct WorkspaceInfraFileInfo {
  var info: FileInfo
  var category: String
  var provider: String
  var kind: String
  var format: String
  var matchSource: String
  var jsonReadable: Bool
  var tomlReadable: Bool
  var fileExtension: String

  var yamlReadable: Bool {
    format == "yaml"
  }

  var xmlReadable: Bool {
    format == "xml"
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "provider": .string(provider),
      "kind": .string(kind),
      "format": .string(format),
      "match_source": .string(matchSource),
      "json_readable": .bool(jsonReadable),
      "toml_readable": .bool(tomlReadable),
      "yaml_readable": .bool(yamlReadable),
      "xml_readable": .bool(xmlReadable),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "read_lines_context": .object([
        "tool": .string("file.read_lines"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "json_context": jsonReadable
        ? .object([
          "tool": .string("json.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "toml_context": tomlReadable
        ? .object([
          "tool": .string("toml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "yaml_context": yamlReadable
        ? .object([
          "tool": .string("yaml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct WorkspaceConfigFileDescriptor {
  var tool: String
  var category: String
  var matchSource: String
}

internal struct WorkspaceConfigFileInfo {
  var info: FileInfo
  var tool: String
  var category: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "tool": .string(tool),
      "category": .string(category),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
    ])
  }
}

internal struct WorkspaceIgnoreFileDescriptor {
  var provider: String
  var category: String
  var matchSource: String
}

internal struct WorkspaceIgnoreFileInfo {
  var info: FileInfo
  var provider: String
  var category: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "provider": .string(provider),
      "category": .string(category),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "read_context": .object([
        "tool": .string("file.read"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ])
  }
}

internal struct WorkspaceAssetFileDescriptor {
  var category: String
  var subtype: String
  var fileExtension: String = ""
}

internal struct WorkspaceAssetFileInfo {
  var info: FileInfo
  var category: String
  var subtype: String
  var fileExtension: String

  var json: JSONValue {
    var object: [String: JSONValue] = [
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "subtype": .string(subtype),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ]
    if category == "image" {
      object["image_info_context"] = .object([
        "tool": .string("image.info"),
        "path": .string(info.workspaceRelativePath),
      ])
    }
    if category == "document", subtype == "pdf" {
      object["pdf_info_context"] = .object([
        "tool": .string("pdf.info"),
        "path": .string(info.workspaceRelativePath),
      ])
      object["pdf_text_context"] = .object([
        "tool": .string("pdf.text"),
        "path": .string(info.workspaceRelativePath),
      ])
    }
    if category == "audio" || category == "video" {
      object["media_info_context"] = .object([
        "tool": .string("media.info"),
        "path": .string(info.workspaceRelativePath),
      ])
    }
    return .object(object)
  }
}

internal struct WorkspaceArchiveFileDescriptor {
  var suffix: String
  var fileExtension: String
  var category: String
  var format: String
  var listSupported: Bool
}

internal struct WorkspaceArchiveFileInfo {
  var info: FileInfo
  var category: String
  var format: String
  var fileExtension: String
  var listSupported: Bool

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "format": .string(format),
      "list_supported": .bool(listSupported),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "list_context": listSupported
        ? .object([
          "tool": .string("archive.list"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "read_file_context": listSupported
        ? .object([
          "tool": .string("archive.read_file"),
          "path": .string(info.workspaceRelativePath),
          "entry": .null,
        ])
        : .null,
    ])
  }
}

internal struct WorkspaceLogFileDescriptor {
  var category: String
  var kind: String
  var matchSource: String
  var fileExtension: String = ""
}

internal struct WorkspaceLogFileInfo {
  var info: FileInfo
  var category: String
  var kind: String
  var matchSource: String
  var fileExtension: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "kind": .string(kind),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "tail_context": .object([
        "tool": .string("file.tail"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "search_context": .object([
        "tool": .string("file.search"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
    ])
  }
}

internal struct WorkspaceDataFileDescriptor {
  var category: String
  var format: String
  var textReadable: Bool
  var jsonReadable: Bool
  var jsonLinesReadable: Bool = false
  var matchSource: String = "extension"
  var fileExtension: String = ""
}

internal struct WorkspaceDataFileInfo {
  var info: FileInfo
  var category: String
  var format: String
  var matchSource: String
  var textReadable: Bool
  var jsonReadable: Bool
  var jsonLinesReadable: Bool
  var fileExtension: String

  var yamlReadable: Bool {
    format == "yaml"
  }

  var xmlReadable: Bool {
    format == "xml"
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "format": .string(format),
      "match_source": .string(matchSource),
      "text_readable": .bool(textReadable),
      "json_readable": .bool(jsonReadable),
      "jsonl_readable": .bool(jsonLinesReadable),
      "yaml_readable": .bool(yamlReadable),
      "xml_readable": .bool(xmlReadable),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "read_lines_context": textReadable
        ? .object([
          "tool": .string("file.read_lines"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "tail_context": textReadable
        ? .object([
          "tool": .string("file.tail"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "count_context": textReadable
        ? .object([
          "tool": .string("file.count"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "json_context": jsonReadable
        ? .object([
          "tool": .string("json.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "jsonl_context": jsonLinesReadable
        ? .object([
          "tool": .string("jsonl.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "yaml_context": yamlReadable
        ? .object([
          "tool": .string("yaml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct WorkspaceSchemaFileDescriptor {
  var category: String
  var schemaKind: String
  var format: String
  var jsonReadable: Bool
  var matchSource: String = "extension"
  var fileExtension: String = ""
}

internal struct WorkspaceSchemaFileInfo {
  var info: FileInfo
  var category: String
  var schemaKind: String
  var format: String
  var matchSource: String
  var jsonReadable: Bool
  var fileExtension: String

  var yamlReadable: Bool {
    format == "yaml"
  }

  var xmlReadable: Bool {
    format == "xml"
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "schema_kind": .string(schemaKind),
      "format": .string(format),
      "match_source": .string(matchSource),
      "json_readable": .bool(jsonReadable),
      "yaml_readable": .bool(yamlReadable),
      "xml_readable": .bool(xmlReadable),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "read_lines_context": .object([
        "tool": .string("file.read_lines"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.workspaceRelativePath),
      ]),
      "json_context": jsonReadable
        ? .object([
          "tool": .string("json.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "yaml_context": yamlReadable
        ? .object([
          "tool": .string("yaml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.workspaceRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct WorkspaceSourceFileDescriptor {
  var language: String
  var kind: String
  var matchSource: String = "extension"
}

internal struct WorkspaceSourceFileInfo {
  var info: FileInfo
  var language: String
  var kind: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "name": .string((info.workspaceRelativePath as NSString).lastPathComponent),
      "language": .string(language),
      "kind": .string(kind),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
    ])
  }
}

private struct WorkspaceCommandManifestReadResult {
  var content: String
  var fileTruncated: Bool
  var parseError: String?
}

internal struct WorkspaceCommandManifestParseResult {
  var commands: [WorkspaceCommandInfo]
  var errors: [WorkspaceCommandParseError]
  var fileTruncated: Bool
}

internal struct WorkspaceCommandParseError {
  var sourceWorkspaceRelativePath: String
  var message: String

  var json: JSONValue {
    .object([
      "source_workspace_relative_path": .string(sourceWorkspaceRelativePath),
      "message": .string(message),
    ])
  }
}

internal struct WorkspaceCommandInfo {
  var sourcePath: String
  var sourceWorkspaceRelativePath: String
  var cwdWorkspaceRelativePath: String
  var ecosystem: String
  var kind: String
  var name: String
  var definition: String?
  var definitionTruncated: Bool
  var definitionSource: String
  var executorTool: String
  var suggestedCLIID: String
  var registeredCLIProvider: Bool
  var requiredExecutable: String
  var argv: [String]
  var fileTruncated: Bool

  var json: JSONValue {
    .object([
      "source_path": .string(sourcePath),
      "source_workspace_relative_path": .string(sourceWorkspaceRelativePath),
      "cwd_workspace_relative_path": .string(cwdWorkspaceRelativePath),
      "ecosystem": .string(ecosystem),
      "kind": .string(kind),
      "name": .string(name),
      "definition": definition.map(JSONValue.string) ?? .null,
      "definition_truncated": .bool(definitionTruncated),
      "definition_source": .string(definitionSource),
      "executor_tool": .string(executorTool),
      "suggested_cli_id": .string(suggestedCLIID),
      "registered_cli_provider": .bool(registeredCLIProvider),
      "required_executable": .string(requiredExecutable),
      "argv": .array(argv.map(JSONValue.string)),
      "file_truncated": .bool(fileTruncated),
    ])
  }
}
