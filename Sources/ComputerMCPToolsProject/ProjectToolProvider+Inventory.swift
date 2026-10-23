import ComputerMCPCore
import ComputerMCPToolKit
import Foundation
import TOML

extension ProjectToolProvider {
  internal static let projectManifestCandidates = [
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

  internal static let dependencyFileDescriptors: [ProjectDependencyFileDescriptor] = [
    ProjectDependencyFileDescriptor(name: "Package.swift", ecosystem: "swift", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "Package.resolved", ecosystem: "swift", role: "lock"),
    ProjectDependencyFileDescriptor(name: "package.json", ecosystem: "node", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "package-lock.json", ecosystem: "node", role: "lock"),
    ProjectDependencyFileDescriptor(name: "npm-shrinkwrap.json", ecosystem: "node", role: "lock"),
    ProjectDependencyFileDescriptor(name: "pnpm-lock.yaml", ecosystem: "node", role: "lock"),
    ProjectDependencyFileDescriptor(name: "yarn.lock", ecosystem: "node", role: "lock"),
    ProjectDependencyFileDescriptor(name: "bun.lock", ecosystem: "node", role: "lock"),
    ProjectDependencyFileDescriptor(name: "bun.lockb", ecosystem: "node", role: "lock"),
    ProjectDependencyFileDescriptor(
      name: "pyproject.toml", ecosystem: "python", role: "manifest"),
    ProjectDependencyFileDescriptor(
      name: "requirements.txt", ecosystem: "python", role: "requirements"),
    ProjectDependencyFileDescriptor(
      name: "requirements-dev.txt", ecosystem: "python", role: "requirements"),
    ProjectDependencyFileDescriptor(name: "poetry.lock", ecosystem: "python", role: "lock"),
    ProjectDependencyFileDescriptor(name: "uv.lock", ecosystem: "python", role: "lock"),
    ProjectDependencyFileDescriptor(name: "Pipfile", ecosystem: "python", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "Pipfile.lock", ecosystem: "python", role: "lock"),
    ProjectDependencyFileDescriptor(name: "setup.py", ecosystem: "python", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "setup.cfg", ecosystem: "python", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "Cargo.toml", ecosystem: "rust", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "Cargo.lock", ecosystem: "rust", role: "lock"),
    ProjectDependencyFileDescriptor(name: "go.mod", ecosystem: "go", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "go.sum", ecosystem: "go", role: "checksum"),
    ProjectDependencyFileDescriptor(name: "pom.xml", ecosystem: "jvm", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "build.gradle", ecosystem: "jvm", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "build.gradle.kts", ecosystem: "jvm", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "settings.gradle", ecosystem: "jvm", role: "manifest"),
    ProjectDependencyFileDescriptor(
      name: "settings.gradle.kts", ecosystem: "jvm", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "gradle.lockfile", ecosystem: "jvm", role: "lock"),
    ProjectDependencyFileDescriptor(name: "Gemfile", ecosystem: "ruby", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "Gemfile.lock", ecosystem: "ruby", role: "lock"),
    ProjectDependencyFileDescriptor(name: "composer.json", ecosystem: "php", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "composer.lock", ecosystem: "php", role: "lock"),
    ProjectDependencyFileDescriptor(name: "pubspec.yaml", ecosystem: "dart", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "pubspec.lock", ecosystem: "dart", role: "lock"),
    ProjectDependencyFileDescriptor(name: "Mix.exs", ecosystem: "elixir", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "mix.lock", ecosystem: "elixir", role: "lock"),
    ProjectDependencyFileDescriptor(name: "Project.toml", ecosystem: "julia", role: "manifest"),
    ProjectDependencyFileDescriptor(name: "Manifest.toml", ecosystem: "julia", role: "lock"),
  ]

  private static let documentationFileDescriptors: [String: ProjectDocumentationDescriptor] = [
    "agents.md": ProjectDocumentationDescriptor(
      category: "agent_instructions", source: "filename"),
    "readme": ProjectDocumentationDescriptor(category: "overview", source: "filename"),
    "contributing": ProjectDocumentationDescriptor(category: "contribution", source: "filename"),
    "code_of_conduct": ProjectDocumentationDescriptor(
      category: "code_of_conduct", source: "filename"),
    "security": ProjectDocumentationDescriptor(category: "security", source: "filename"),
    "support": ProjectDocumentationDescriptor(category: "support", source: "filename"),
    "changelog": ProjectDocumentationDescriptor(category: "changelog", source: "filename"),
    "changes": ProjectDocumentationDescriptor(category: "changelog", source: "filename"),
    "release_notes": ProjectDocumentationDescriptor(category: "changelog", source: "filename"),
    "license": ProjectDocumentationDescriptor(category: "license", source: "filename"),
    "licence": ProjectDocumentationDescriptor(category: "license", source: "filename"),
    "copying": ProjectDocumentationDescriptor(category: "license", source: "filename"),
    "notice": ProjectDocumentationDescriptor(category: "notice", source: "filename"),
  ]

  private static let agentFileDescriptors: [String: ProjectAgentFileDescriptor] = [
    "agents.md": ProjectAgentFileDescriptor(kind: "codex", source: "filename"),
    "claude.md": ProjectAgentFileDescriptor(kind: "claude", source: "filename"),
    "gemini.md": ProjectAgentFileDescriptor(kind: "gemini", source: "filename"),
    "copilot-instructions.md": ProjectAgentFileDescriptor(
      kind: "github_copilot", source: "filename"),
    ".cursorrules": ProjectAgentFileDescriptor(kind: "cursor", source: "filename"),
    ".windsurfrules": ProjectAgentFileDescriptor(kind: "windsurf", source: "filename"),
    "windsurf.md": ProjectAgentFileDescriptor(kind: "windsurf", source: "filename"),
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

  private static let artifactDirectoryDescriptors: [String: ProjectArtifactDirectoryDescriptor] =
    [
      ".build": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "swiftpm_build", cleanupRisk: "recreatable"),
      "build": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "generic_build", cleanupRisk: "recreatable"),
      "dist": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "distribution_output", cleanupRisk: "recreatable"),
      "out": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "generic_output", cleanupRisk: "recreatable"),
      "target": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "rust_or_jvm_build", cleanupRisk: "recreatable"),
      "deriveddata": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "xcode_derived_data", cleanupRisk: "recreatable"),
      ".next": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "nextjs_build", cleanupRisk: "recreatable"),
      ".nuxt": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "nuxt_build", cleanupRisk: "recreatable"),
      ".svelte-kit": ProjectArtifactDirectoryDescriptor(
        category: "build_output", kind: "sveltekit_build", cleanupRisk: "recreatable"),
      "node_modules": ProjectArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "node_dependencies", cleanupRisk: "reinstallable"),
      "vendor": ProjectArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "vendored_dependencies", cleanupRisk: "review"),
      "pods": ProjectArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "cocoapods_dependencies", cleanupRisk: "reinstallable"
      ),
      "carthage": ProjectArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "carthage_dependencies", cleanupRisk: "reinstallable"),
      ".venv": ProjectArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "python_virtualenv", cleanupRisk: "reinstallable"),
      "venv": ProjectArtifactDirectoryDescriptor(
        category: "dependency_install", kind: "python_virtualenv", cleanupRisk: "reinstallable"),
      ".cache": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "generic_cache", cleanupRisk: "recreatable"),
      "cache": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "generic_cache", cleanupRisk: "review"),
      ".turbo": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "turbo_cache", cleanupRisk: "recreatable"),
      ".parcel-cache": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "parcel_cache", cleanupRisk: "recreatable"),
      ".pnpm-store": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "pnpm_store", cleanupRisk: "recreatable"),
      ".pytest_cache": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "pytest_cache", cleanupRisk: "recreatable"),
      ".mypy_cache": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "mypy_cache", cleanupRisk: "recreatable"),
      ".ruff_cache": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "ruff_cache", cleanupRisk: "recreatable"),
      "__pycache__": ProjectArtifactDirectoryDescriptor(
        category: "cache", kind: "python_bytecode_cache", cleanupRisk: "recreatable"),
      "coverage": ProjectArtifactDirectoryDescriptor(
        category: "coverage_output", kind: "test_coverage", cleanupRisk: "recreatable"),
      ".nyc_output": ProjectArtifactDirectoryDescriptor(
        category: "coverage_output", kind: "nyc_coverage", cleanupRisk: "recreatable"),
      "tmp": ProjectArtifactDirectoryDescriptor(
        category: "temporary", kind: "temporary_directory", cleanupRisk: "review"),
      "temp": ProjectArtifactDirectoryDescriptor(
        category: "temporary", kind: "temporary_directory", cleanupRisk: "review"),
      ".tmp": ProjectArtifactDirectoryDescriptor(
        category: "temporary", kind: "temporary_directory", cleanupRisk: "review"),
      "generated": ProjectArtifactDirectoryDescriptor(
        category: "generated_candidate", kind: "generated_directory", cleanupRisk: "review"),
      "gen": ProjectArtifactDirectoryDescriptor(
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

  private static let sourceFileExtensions: [String: ProjectSourceFileDescriptor] = [
    "swift": ProjectSourceFileDescriptor(language: "swift", kind: "source"),
    "js": ProjectSourceFileDescriptor(language: "javascript", kind: "source"),
    "jsx": ProjectSourceFileDescriptor(language: "javascript", kind: "source"),
    "ts": ProjectSourceFileDescriptor(language: "typescript", kind: "source"),
    "tsx": ProjectSourceFileDescriptor(language: "typescript", kind: "source"),
    "mjs": ProjectSourceFileDescriptor(language: "javascript", kind: "source"),
    "cjs": ProjectSourceFileDescriptor(language: "javascript", kind: "source"),
    "py": ProjectSourceFileDescriptor(language: "python", kind: "source"),
    "rb": ProjectSourceFileDescriptor(language: "ruby", kind: "source"),
    "go": ProjectSourceFileDescriptor(language: "go", kind: "source"),
    "rs": ProjectSourceFileDescriptor(language: "rust", kind: "source"),
    "java": ProjectSourceFileDescriptor(language: "java", kind: "source"),
    "kt": ProjectSourceFileDescriptor(language: "kotlin", kind: "source"),
    "kts": ProjectSourceFileDescriptor(language: "kotlin", kind: "source"),
    "scala": ProjectSourceFileDescriptor(language: "scala", kind: "source"),
    "cs": ProjectSourceFileDescriptor(language: "csharp", kind: "source"),
    "php": ProjectSourceFileDescriptor(language: "php", kind: "source"),
    "dart": ProjectSourceFileDescriptor(language: "dart", kind: "source"),
    "ex": ProjectSourceFileDescriptor(language: "elixir", kind: "source"),
    "exs": ProjectSourceFileDescriptor(language: "elixir", kind: "source"),
    "erl": ProjectSourceFileDescriptor(language: "erlang", kind: "source"),
    "hrl": ProjectSourceFileDescriptor(language: "erlang", kind: "header"),
    "c": ProjectSourceFileDescriptor(language: "c", kind: "source"),
    "h": ProjectSourceFileDescriptor(language: "c", kind: "header"),
    "cpp": ProjectSourceFileDescriptor(language: "cpp", kind: "source"),
    "cc": ProjectSourceFileDescriptor(language: "cpp", kind: "source"),
    "cxx": ProjectSourceFileDescriptor(language: "cpp", kind: "source"),
    "hpp": ProjectSourceFileDescriptor(language: "cpp", kind: "header"),
    "hh": ProjectSourceFileDescriptor(language: "cpp", kind: "header"),
    "hxx": ProjectSourceFileDescriptor(language: "cpp", kind: "header"),
    "m": ProjectSourceFileDescriptor(language: "objective-c", kind: "source"),
    "mm": ProjectSourceFileDescriptor(language: "objective-cpp", kind: "source"),
    "sh": ProjectSourceFileDescriptor(language: "shell", kind: "script"),
    "bash": ProjectSourceFileDescriptor(language: "shell", kind: "script"),
    "zsh": ProjectSourceFileDescriptor(language: "shell", kind: "script"),
    "fish": ProjectSourceFileDescriptor(language: "fish", kind: "script"),
    "ps1": ProjectSourceFileDescriptor(language: "powershell", kind: "script"),
    "sql": ProjectSourceFileDescriptor(language: "sql", kind: "query"),
    "html": ProjectSourceFileDescriptor(language: "html", kind: "markup"),
    "htm": ProjectSourceFileDescriptor(language: "html", kind: "markup"),
    "css": ProjectSourceFileDescriptor(language: "css", kind: "style"),
    "scss": ProjectSourceFileDescriptor(language: "scss", kind: "style"),
    "sass": ProjectSourceFileDescriptor(language: "sass", kind: "style"),
    "less": ProjectSourceFileDescriptor(language: "less", kind: "style"),
    "vue": ProjectSourceFileDescriptor(language: "vue", kind: "component"),
    "svelte": ProjectSourceFileDescriptor(language: "svelte", kind: "component"),
    "astro": ProjectSourceFileDescriptor(language: "astro", kind: "component"),
  ]

  private static let assetFileExtensions: [String: ProjectAssetFileDescriptor] = [
    "png": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "jpg": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "jpeg": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "gif": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "webp": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "avif": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "heic": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "heif": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "tif": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "tiff": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "bmp": ProjectAssetFileDescriptor(category: "image", subtype: "bitmap"),
    "ico": ProjectAssetFileDescriptor(category: "image", subtype: "icon"),
    "icns": ProjectAssetFileDescriptor(category: "image", subtype: "icon"),
    "svg": ProjectAssetFileDescriptor(category: "image", subtype: "vector"),
    "ttf": ProjectAssetFileDescriptor(category: "font", subtype: "truetype"),
    "otf": ProjectAssetFileDescriptor(category: "font", subtype: "opentype"),
    "woff": ProjectAssetFileDescriptor(category: "font", subtype: "webfont"),
    "woff2": ProjectAssetFileDescriptor(category: "font", subtype: "webfont"),
    "eot": ProjectAssetFileDescriptor(category: "font", subtype: "webfont"),
    "mp3": ProjectAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "m4a": ProjectAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "aac": ProjectAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "ogg": ProjectAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "opus": ProjectAssetFileDescriptor(category: "audio", subtype: "compressed"),
    "flac": ProjectAssetFileDescriptor(category: "audio", subtype: "lossless"),
    "wav": ProjectAssetFileDescriptor(category: "audio", subtype: "waveform"),
    "mp4": ProjectAssetFileDescriptor(category: "video", subtype: "container"),
    "m4v": ProjectAssetFileDescriptor(category: "video", subtype: "container"),
    "mov": ProjectAssetFileDescriptor(category: "video", subtype: "container"),
    "webm": ProjectAssetFileDescriptor(category: "video", subtype: "container"),
    "avi": ProjectAssetFileDescriptor(category: "video", subtype: "container"),
    "mkv": ProjectAssetFileDescriptor(category: "video", subtype: "container"),
    "pdf": ProjectAssetFileDescriptor(category: "document", subtype: "pdf"),
    "key": ProjectAssetFileDescriptor(category: "document", subtype: "presentation"),
    "ppt": ProjectAssetFileDescriptor(category: "document", subtype: "presentation"),
    "pptx": ProjectAssetFileDescriptor(category: "document", subtype: "presentation"),
    "doc": ProjectAssetFileDescriptor(category: "document", subtype: "word_processing"),
    "docx": ProjectAssetFileDescriptor(category: "document", subtype: "word_processing"),
    "sketch": ProjectAssetFileDescriptor(category: "design", subtype: "source"),
    "fig": ProjectAssetFileDescriptor(category: "design", subtype: "source"),
    "psd": ProjectAssetFileDescriptor(category: "design", subtype: "source"),
    "ai": ProjectAssetFileDescriptor(category: "design", subtype: "source"),
    "xd": ProjectAssetFileDescriptor(category: "design", subtype: "source"),
  ]

  private static let archiveFileDescriptors: [ProjectArchiveFileDescriptor] = [
    ProjectArchiveFileDescriptor(
      suffix: ".tar.gz", fileExtension: "tar.gz", category: "archive", format: "tar_gzip",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".tar.bz2", fileExtension: "tar.bz2", category: "archive", format: "tar_bzip2",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".tar.xz", fileExtension: "tar.xz", category: "archive", format: "tar_xz",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".zip", fileExtension: "zip", category: "archive", format: "zip",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".jar", fileExtension: "jar", category: "application_package", format: "zip",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".war", fileExtension: "war", category: "application_package", format: "zip",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".ear", fileExtension: "ear", category: "application_package", format: "zip",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".tar", fileExtension: "tar", category: "archive", format: "tar",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".tgz", fileExtension: "tgz", category: "archive", format: "tar_gzip",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".tbz", fileExtension: "tbz", category: "archive", format: "tar_bzip2",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".tbz2", fileExtension: "tbz2", category: "archive", format: "tar_bzip2",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".txz", fileExtension: "txz", category: "archive", format: "tar_xz",
      listSupported: true),
    ProjectArchiveFileDescriptor(
      suffix: ".7z", fileExtension: "7z", category: "archive", format: "7z",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".rar", fileExtension: "rar", category: "archive", format: "rar",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".gz", fileExtension: "gz", category: "compressed_stream", format: "gzip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".bz2", fileExtension: "bz2", category: "compressed_stream", format: "bzip2",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".xz", fileExtension: "xz", category: "compressed_stream", format: "xz",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".dmg", fileExtension: "dmg", category: "disk_image", format: "dmg",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".pkg", fileExtension: "pkg", category: "installer", format: "pkg",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".mpkg", fileExtension: "mpkg", category: "installer", format: "mpkg",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".ipa", fileExtension: "ipa", category: "application_package", format: "zip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".apk", fileExtension: "apk", category: "application_package", format: "zip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".aab", fileExtension: "aab", category: "application_package", format: "zip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".nupkg", fileExtension: "nupkg", category: "application_package", format: "zip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".vsix", fileExtension: "vsix", category: "application_package", format: "zip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".xpi", fileExtension: "xpi", category: "application_package", format: "zip",
      listSupported: false),
    ProjectArchiveFileDescriptor(
      suffix: ".crx", fileExtension: "crx", category: "application_package", format: "crx",
      listSupported: false),
  ]

  private static let logExactFileDescriptors: [String: ProjectLogFileDescriptor] = [
    "access.log": ProjectLogFileDescriptor(
      category: "application_log", kind: "access", matchSource: "filename"),
    "debug.log": ProjectLogFileDescriptor(
      category: "application_log", kind: "debug", matchSource: "filename"),
    "error.log": ProjectLogFileDescriptor(
      category: "application_log", kind: "error", matchSource: "filename"),
    "npm-debug.log": ProjectLogFileDescriptor(
      category: "package_manager_log", kind: "debug", matchSource: "filename"),
    "pnpm-debug.log": ProjectLogFileDescriptor(
      category: "package_manager_log", kind: "debug", matchSource: "filename"),
    "yarn-error.log": ProjectLogFileDescriptor(
      category: "package_manager_log", kind: "error", matchSource: "filename"),
  ]

  private static let logFileExtensions: [String: ProjectLogFileDescriptor] = [
    "crash": ProjectLogFileDescriptor(
      category: "crash_report", kind: "crash", matchSource: "extension"),
    "err": ProjectLogFileDescriptor(
      category: "process_output", kind: "stderr", matchSource: "extension"),
    "ips": ProjectLogFileDescriptor(
      category: "crash_report", kind: "crash", matchSource: "extension"),
    "log": ProjectLogFileDescriptor(
      category: "application_log", kind: "log", matchSource: "extension"),
    "out": ProjectLogFileDescriptor(
      category: "process_output", kind: "stdout", matchSource: "extension"),
    "trace": ProjectLogFileDescriptor(
      category: "trace", kind: "trace", matchSource: "extension"),
  ]

  private static let dataFileExtensions: [String: ProjectDataFileDescriptor] = [
    "arrow": ProjectDataFileDescriptor(
      category: "columnar_data", format: "arrow", textReadable: false, jsonReadable: false),
    "avro": ProjectDataFileDescriptor(
      category: "record_data", format: "avro", textReadable: false, jsonReadable: false),
    "csv": ProjectDataFileDescriptor(
      category: "tabular_data", format: "csv", textReadable: true, jsonReadable: false),
    "db": ProjectDataFileDescriptor(
      category: "database", format: "sqlite_or_database", textReadable: false,
      jsonReadable: false),
    "db3": ProjectDataFileDescriptor(
      category: "database", format: "sqlite", textReadable: false, jsonReadable: false),
    "duckdb": ProjectDataFileDescriptor(
      category: "database", format: "duckdb", textReadable: false, jsonReadable: false),
    "feather": ProjectDataFileDescriptor(
      category: "columnar_data", format: "feather", textReadable: false, jsonReadable: false),
    "jsonl": ProjectDataFileDescriptor(
      category: "record_data", format: "json_lines", textReadable: true, jsonReadable: false,
      jsonLinesReadable: true),
    "ndjson": ProjectDataFileDescriptor(
      category: "record_data", format: "ndjson", textReadable: true, jsonReadable: false,
      jsonLinesReadable: true),
    "orc": ProjectDataFileDescriptor(
      category: "columnar_data", format: "orc", textReadable: false, jsonReadable: false),
    "parquet": ProjectDataFileDescriptor(
      category: "columnar_data", format: "parquet", textReadable: false, jsonReadable: false),
    "psv": ProjectDataFileDescriptor(
      category: "tabular_data", format: "pipe_separated_values", textReadable: true,
      jsonReadable: false),
    "sqlite": ProjectDataFileDescriptor(
      category: "database", format: "sqlite", textReadable: false, jsonReadable: false),
    "sqlite3": ProjectDataFileDescriptor(
      category: "database", format: "sqlite", textReadable: false, jsonReadable: false),
    "tsv": ProjectDataFileDescriptor(
      category: "tabular_data", format: "tab_separated_values", textReadable: true,
      jsonReadable: false),
    "xls": ProjectDataFileDescriptor(
      category: "spreadsheet_data", format: "excel", textReadable: false, jsonReadable: false),
    "xlsx": ProjectDataFileDescriptor(
      category: "spreadsheet_data", format: "excel", textReadable: false, jsonReadable: false),
  ]

  private static let directoryScopedDataFileDescriptors: [String: ProjectDataFileDescriptor] = [
    "json": ProjectDataFileDescriptor(
      category: "structured_data", format: "json", textReadable: true, jsonReadable: true,
      matchSource: "data_directory"),
    "json5": ProjectDataFileDescriptor(
      category: "structured_data", format: "json5", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "plist": ProjectDataFileDescriptor(
      category: "structured_data", format: "plist", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "toml": ProjectDataFileDescriptor(
      category: "structured_data", format: "toml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "xml": ProjectDataFileDescriptor(
      category: "structured_data", format: "xml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "yaml": ProjectDataFileDescriptor(
      category: "structured_data", format: "yaml", textReadable: true, jsonReadable: false,
      matchSource: "data_directory"),
    "yml": ProjectDataFileDescriptor(
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

  private static let schemaExactFileDescriptors: [String: ProjectSchemaFileDescriptor] = [
    "asyncapi.json": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "asyncapi", format: "json", jsonReadable: true,
      matchSource: "filename"),
    "asyncapi.yaml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "asyncapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "asyncapi.yml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "asyncapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "openapi.json": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "openapi", format: "json", jsonReadable: true,
      matchSource: "filename"),
    "openapi.yaml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "openapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "openapi.yml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "openapi", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "schema.graphql": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false, matchSource: "filename"),
    "schema.graphqls": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false, matchSource: "filename"),
    "schema.prisma": ProjectSchemaFileDescriptor(
      category: "database_schema", schemaKind: "prisma", format: "prisma",
      jsonReadable: false, matchSource: "filename"),
    "swagger.json": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "swagger", format: "json", jsonReadable: true,
      matchSource: "filename"),
    "swagger.yaml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "swagger", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
    "swagger.yml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "swagger", format: "yaml", jsonReadable: false,
      matchSource: "filename"),
  ]

  private static let schemaFileExtensions: [String: ProjectSchemaFileDescriptor] = [
    "avdl": ProjectSchemaFileDescriptor(
      category: "data_schema", schemaKind: "avro_idl", format: "avro_idl",
      jsonReadable: false),
    "avpr": ProjectSchemaFileDescriptor(
      category: "data_schema", schemaKind: "avro_protocol", format: "json",
      jsonReadable: true),
    "avsc": ProjectSchemaFileDescriptor(
      category: "data_schema", schemaKind: "avro_schema", format: "json",
      jsonReadable: true),
    "capnp": ProjectSchemaFileDescriptor(
      category: "data_schema", schemaKind: "capn_proto", format: "capnp",
      jsonReadable: false),
    "fbs": ProjectSchemaFileDescriptor(
      category: "data_schema", schemaKind: "flatbuffers", format: "flatbuffers",
      jsonReadable: false),
    "gql": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false),
    "graphql": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false),
    "graphqls": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "graphql", format: "graphql",
      jsonReadable: false),
    "prisma": ProjectSchemaFileDescriptor(
      category: "database_schema", schemaKind: "prisma", format: "prisma",
      jsonReadable: false),
    "proto": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "protobuf", format: "protobuf",
      jsonReadable: false),
    "raml": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "raml", format: "raml", jsonReadable: false),
    "thrift": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "thrift", format: "thrift",
      jsonReadable: false),
    "wsdl": ProjectSchemaFileDescriptor(
      category: "api_contract", schemaKind: "wsdl", format: "xml", jsonReadable: false),
    "xsd": ProjectSchemaFileDescriptor(
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

  private static let infraExactFileDescriptors: [String: ProjectInfraFileDescriptor] = [
    "cdk.json": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "aws_cdk", kind: "project_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "chart.yaml": ProjectInfraFileDescriptor(
      category: "package_deployment", provider: "helm", kind: "chart",
      format: "yaml", matchSource: "filename"),
    "compose.yaml": ProjectInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "compose.yml": ProjectInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "containerfile": ProjectInfraFileDescriptor(
      category: "container", provider: "containerfile", kind: "image_build",
      format: "containerfile", matchSource: "filename"),
    "devcontainer.json": ProjectInfraFileDescriptor(
      category: "development_container", provider: "devcontainer", kind: "dev_environment",
      format: "json", matchSource: "filename", jsonReadable: true),
    "docker-compose.yaml": ProjectInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "docker-compose.yml": ProjectInfraFileDescriptor(
      category: "container_orchestration", provider: "docker_compose", kind: "compose_file",
      format: "yaml", matchSource: "filename"),
    "dockerfile": ProjectInfraFileDescriptor(
      category: "container", provider: "docker", kind: "image_build", format: "dockerfile",
      matchSource: "filename"),
    "fly.toml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "fly", kind: "deployment_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
    "kustomization.yaml": ProjectInfraFileDescriptor(
      category: "orchestration", provider: "kustomize", kind: "kustomization",
      format: "yaml", matchSource: "filename"),
    "kustomization.yml": ProjectInfraFileDescriptor(
      category: "orchestration", provider: "kustomize", kind: "kustomization",
      format: "yaml", matchSource: "filename"),
    "netlify.toml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "netlify", kind: "deployment_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
    "procfile": ProjectInfraFileDescriptor(
      category: "process_deployment", provider: "process_manager", kind: "process_profile",
      format: "procfile", matchSource: "filename"),
    "pulumi.json": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "pulumi", kind: "stack_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "pulumi.yaml": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "pulumi", kind: "stack_config",
      format: "yaml", matchSource: "filename"),
    "pulumi.yml": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "pulumi", kind: "stack_config",
      format: "yaml", matchSource: "filename"),
    "railway.json": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "railway", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "render.yaml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "render", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "render.yml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "render", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "samconfig.toml": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "aws_sam", kind: "project_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
    "serverless.json": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "serverless", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "serverless.yaml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "serverless", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "serverless.yml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "serverless", kind: "deployment_config",
      format: "yaml", matchSource: "filename"),
    "skaffold.yaml": ProjectInfraFileDescriptor(
      category: "orchestration", provider: "skaffold", kind: "pipeline",
      format: "yaml", matchSource: "filename"),
    "skaffold.yml": ProjectInfraFileDescriptor(
      category: "orchestration", provider: "skaffold", kind: "pipeline",
      format: "yaml", matchSource: "filename"),
    "tiltfile": ProjectInfraFileDescriptor(
      category: "development_orchestration", provider: "tilt", kind: "pipeline",
      format: "starlark", matchSource: "filename"),
    "vercel.json": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "vercel", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "wrangler.json": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "cloudflare", kind: "deployment_config",
      format: "json", matchSource: "filename", jsonReadable: true),
    "wrangler.jsonc": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "cloudflare", kind: "deployment_config",
      format: "jsonc", matchSource: "filename"),
    "wrangler.toml": ProjectInfraFileDescriptor(
      category: "platform_deployment", provider: "cloudflare", kind: "deployment_config",
      format: "toml", matchSource: "filename", tomlReadable: true),
  ]

  private static let infraFileExtensions: [String: ProjectInfraFileDescriptor] = [
    "tf": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "terraform", kind: "module",
      format: "hcl", matchSource: "extension"),
    "tfvars": ProjectInfraFileDescriptor(
      category: "infrastructure_as_code", provider: "terraform", kind: "variables",
      format: "hcl", matchSource: "extension"),
  ]

  private static let configExactFileDescriptors: [String: ProjectConfigFileDescriptor] = [
    ".editorconfig": ProjectConfigFileDescriptor(
      tool: "editorconfig", category: "editor", matchSource: "filename"),
    ".swift-format": ProjectConfigFileDescriptor(
      tool: "swift-format", category: "formatter", matchSource: "filename"),
    "swift-format.json": ProjectConfigFileDescriptor(
      tool: "swift-format", category: "formatter", matchSource: "filename"),
    ".swiftlint.yml": ProjectConfigFileDescriptor(
      tool: "swiftlint", category: "linter", matchSource: "filename"),
    ".swiftlint.yaml": ProjectConfigFileDescriptor(
      tool: "swiftlint", category: "linter", matchSource: "filename"),
    ".prettierrc": ProjectConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.json": ProjectConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.jsonc": ProjectConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.yml": ProjectConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.yaml": ProjectConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".prettierrc.toml": ProjectConfigFileDescriptor(
      tool: "prettier", category: "formatter", matchSource: "filename"),
    ".eslintrc": ProjectConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    ".eslintrc.json": ProjectConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    ".eslintrc.yml": ProjectConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    ".eslintrc.yaml": ProjectConfigFileDescriptor(
      tool: "eslint", category: "linter", matchSource: "filename"),
    "biome.json": ProjectConfigFileDescriptor(
      tool: "biome", category: "formatter_linter", matchSource: "filename"),
    "biome.jsonc": ProjectConfigFileDescriptor(
      tool: "biome", category: "formatter_linter", matchSource: "filename"),
    "rome.json": ProjectConfigFileDescriptor(
      tool: "rome", category: "formatter_linter", matchSource: "filename"),
    "tsconfig.json": ProjectConfigFileDescriptor(
      tool: "typescript", category: "compiler", matchSource: "filename"),
    "jsconfig.json": ProjectConfigFileDescriptor(
      tool: "javascript", category: "language_service", matchSource: "filename"),
    ".stylelintrc": ProjectConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".stylelintrc.json": ProjectConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".stylelintrc.yml": ProjectConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".stylelintrc.yaml": ProjectConfigFileDescriptor(
      tool: "stylelint", category: "linter", matchSource: "filename"),
    ".browserslistrc": ProjectConfigFileDescriptor(
      tool: "browserslist", category: "compatibility", matchSource: "filename"),
    "browserslist": ProjectConfigFileDescriptor(
      tool: "browserslist", category: "compatibility", matchSource: "filename"),
    "ruff.toml": ProjectConfigFileDescriptor(
      tool: "ruff", category: "linter", matchSource: "filename"),
    ".ruff.toml": ProjectConfigFileDescriptor(
      tool: "ruff", category: "linter", matchSource: "filename"),
    "mypy.ini": ProjectConfigFileDescriptor(
      tool: "mypy", category: "type_checker", matchSource: "filename"),
    ".mypy.ini": ProjectConfigFileDescriptor(
      tool: "mypy", category: "type_checker", matchSource: "filename"),
    ".flake8": ProjectConfigFileDescriptor(
      tool: "flake8", category: "linter", matchSource: "filename"),
    "tox.ini": ProjectConfigFileDescriptor(
      tool: "tox", category: "test_runner", matchSource: "filename"),
    "pytest.ini": ProjectConfigFileDescriptor(
      tool: "pytest", category: "test_runner", matchSource: "filename"),
    ".pylintrc": ProjectConfigFileDescriptor(
      tool: "pylint", category: "linter", matchSource: "filename"),
    "pyrightconfig.json": ProjectConfigFileDescriptor(
      tool: "pyright", category: "type_checker", matchSource: "filename"),
    "rustfmt.toml": ProjectConfigFileDescriptor(
      tool: "rustfmt", category: "formatter", matchSource: "filename"),
    ".rustfmt.toml": ProjectConfigFileDescriptor(
      tool: "rustfmt", category: "formatter", matchSource: "filename"),
    "clippy.toml": ProjectConfigFileDescriptor(
      tool: "clippy", category: "linter", matchSource: "filename"),
    ".clippy.toml": ProjectConfigFileDescriptor(
      tool: "clippy", category: "linter", matchSource: "filename"),
    "golangci.yml": ProjectConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    "golangci.yaml": ProjectConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    ".golangci.yml": ProjectConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    ".golangci.yaml": ProjectConfigFileDescriptor(
      tool: "golangci-lint", category: "linter", matchSource: "filename"),
    ".yamllint.yml": ProjectConfigFileDescriptor(
      tool: "yamllint", category: "linter", matchSource: "filename"),
    ".yamllint.yaml": ProjectConfigFileDescriptor(
      tool: "yamllint", category: "linter", matchSource: "filename"),
    ".markdownlint.json": ProjectConfigFileDescriptor(
      tool: "markdownlint", category: "linter", matchSource: "filename"),
    ".markdownlint.yml": ProjectConfigFileDescriptor(
      tool: "markdownlint", category: "linter", matchSource: "filename"),
    ".markdownlint.yaml": ProjectConfigFileDescriptor(
      tool: "markdownlint", category: "linter", matchSource: "filename"),
    ".npmrc": ProjectConfigFileDescriptor(
      tool: "npm", category: "package_manager", matchSource: "filename"),
    ".yarnrc": ProjectConfigFileDescriptor(
      tool: "yarn", category: "package_manager", matchSource: "filename"),
    ".yarnrc.yml": ProjectConfigFileDescriptor(
      tool: "yarn", category: "package_manager", matchSource: "filename"),
    ".pnpmrc": ProjectConfigFileDescriptor(
      tool: "pnpm", category: "package_manager", matchSource: "filename"),
    ".nvmrc": ProjectConfigFileDescriptor(
      tool: "node", category: "toolchain", matchSource: "filename"),
    ".node-version": ProjectConfigFileDescriptor(
      tool: "node", category: "toolchain", matchSource: "filename"),
    ".ruby-version": ProjectConfigFileDescriptor(
      tool: "ruby", category: "toolchain", matchSource: "filename"),
    ".python-version": ProjectConfigFileDescriptor(
      tool: "python", category: "toolchain", matchSource: "filename"),
    ".tool-versions": ProjectConfigFileDescriptor(
      tool: "asdf", category: "toolchain", matchSource: "filename"),
    ".mise.toml": ProjectConfigFileDescriptor(
      tool: "mise", category: "toolchain", matchSource: "filename"),
    ".mise.local.toml": ProjectConfigFileDescriptor(
      tool: "mise", category: "toolchain", matchSource: "filename"),
    ".sdkmanrc": ProjectConfigFileDescriptor(
      tool: "sdkman", category: "toolchain", matchSource: "filename"),
    ".gitignore": ProjectConfigFileDescriptor(
      tool: "git", category: "source_control", matchSource: "filename"),
    ".gitattributes": ProjectConfigFileDescriptor(
      tool: "git", category: "source_control", matchSource: "filename"),
  ]

  private static let ignoreFileDescriptors: [String: ProjectIgnoreFileDescriptor] = [
    ".gitignore": ProjectIgnoreFileDescriptor(
      provider: "git", category: "source_control_ignore", matchSource: "filename"),
    ".git-blame-ignore-revs": ProjectIgnoreFileDescriptor(
      provider: "git", category: "source_control_history_ignore", matchSource: "filename"),
    ".ignore": ProjectIgnoreFileDescriptor(
      provider: "generic", category: "search_ignore", matchSource: "filename"),
    ".rgignore": ProjectIgnoreFileDescriptor(
      provider: "ripgrep", category: "search_ignore", matchSource: "filename"),
    ".fdignore": ProjectIgnoreFileDescriptor(
      provider: "fd", category: "search_ignore", matchSource: "filename"),
    ".dockerignore": ProjectIgnoreFileDescriptor(
      provider: "docker", category: "build_context_ignore", matchSource: "filename"),
    ".npmignore": ProjectIgnoreFileDescriptor(
      provider: "npm", category: "package_publish_ignore", matchSource: "filename"),
    ".eslintignore": ProjectIgnoreFileDescriptor(
      provider: "eslint", category: "linter_ignore", matchSource: "filename"),
    ".prettierignore": ProjectIgnoreFileDescriptor(
      provider: "prettier", category: "formatter_ignore", matchSource: "filename"),
    ".stylelintignore": ProjectIgnoreFileDescriptor(
      provider: "stylelint", category: "linter_ignore", matchSource: "filename"),
    ".markdownlintignore": ProjectIgnoreFileDescriptor(
      provider: "markdownlint", category: "linter_ignore", matchSource: "filename"),
    ".yamllintignore": ProjectIgnoreFileDescriptor(
      provider: "yamllint", category: "linter_ignore", matchSource: "filename"),
    ".helmignore": ProjectIgnoreFileDescriptor(
      provider: "helm", category: "package_ignore", matchSource: "filename"),
    ".terraformignore": ProjectIgnoreFileDescriptor(
      provider: "terraform", category: "package_ignore", matchSource: "filename"),
    ".gcloudignore": ProjectIgnoreFileDescriptor(
      provider: "gcloud", category: "deploy_ignore", matchSource: "filename"),
    ".ebignore": ProjectIgnoreFileDescriptor(
      provider: "elastic_beanstalk", category: "deploy_ignore", matchSource: "filename"),
    ".slugignore": ProjectIgnoreFileDescriptor(
      provider: "heroku", category: "deploy_ignore", matchSource: "filename"),
    ".vercelignore": ProjectIgnoreFileDescriptor(
      provider: "vercel", category: "deploy_ignore", matchSource: "filename"),
    ".netlifyignore": ProjectIgnoreFileDescriptor(
      provider: "netlify", category: "deploy_ignore", matchSource: "filename"),
    ".cursorignore": ProjectIgnoreFileDescriptor(
      provider: "cursor", category: "agent_context_ignore", matchSource: "filename"),
    ".aiexclude": ProjectIgnoreFileDescriptor(
      provider: "agent", category: "agent_context_ignore", matchSource: "filename"),
  ]

  internal func directoryStatsDepth(_ relativePath: String) -> Int {
    relativePath.split(separator: "/").count - 1
  }

  internal func directoryStatsGroupPath(
    rootProjectRelativePath: String,
    relativeToRoot: String
  ) -> String {
    guard let first = relativeToRoot.split(separator: "/").first else {
      return rootProjectRelativePath
    }
    if rootProjectRelativePath == "." {
      return String(first)
    }
    return "\(rootProjectRelativePath)/\(first)"
  }

  internal func directoryStatsGroupName(
    _ projectRelativePath: String,
    rootProjectRelativePath: String
  ) -> String {
    if projectRelativePath == rootProjectRelativePath {
      return "."
    }
    return (projectRelativePath as NSString).lastPathComponent
  }

  internal func collectProjectEmptyDirectories(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    scannedDirectoryCount: inout Int,
    hiddenSkippedCount: inout Int,
    emptyDirectories: inout [ProjectEmptyDirectoryInfo],
    scanTruncated: inout Bool
  ) throws {
    guard !scanTruncated else {
      return
    }

    let directoryInfo = try projectScope.fileInfo(url: directory)
    scannedDirectoryCount += 1
    let children = try sortedDirectoryChildren(directory, includeHidden: true)
    if children.isEmpty {
      emptyDirectories.append(
        ProjectEmptyDirectoryInfo(
          path: directoryInfo.path,
          projectRelativePath: directoryInfo.projectRelativePath,
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

      let childInfo = try projectScope.fileInfo(url: child)
      guard childInfo.type == "directory", !childInfo.isSymlink else {
        continue
      }
      if child.lastPathComponent.hasPrefix("."), !includeHidden {
        hiddenSkippedCount += 1
        continue
      }

      try collectProjectEmptyDirectories(
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

  internal func collectProjectArtifactDirectories(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    hiddenSkippedCount: inout Int,
    artifactDirectories: inout [ProjectArtifactDirectoryInfo],
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
      let info = try projectScope.fileInfo(url: child)
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
          ProjectArtifactDirectoryInfo(
            info: info,
            category: descriptor.category,
            kind: descriptor.kind,
            cleanupRisk: descriptor.cleanupRisk,
            matchSource: "directory_name"
          ))
        continue
      }

      if currentDepth < maxDepth {
        try collectProjectArtifactDirectories(
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
    -> ProjectArtifactDirectoryDescriptor?
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
    matches: inout [ProjectTodoMatch],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard !truncated else {
        return
      }

      let resolved = try projectScope.resolvedProjectURLPreservingFinalSymlink(child.path)
      let info = try projectScope.fileInfo(url: resolved)
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
    matches: inout [ProjectTodoMatch],
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
    matches: inout [ProjectTodoMatch],
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
          ProjectTodoMatch(
            marker: markers[lineMatch.markerIndex],
            path: fileInfo.path,
            projectRelativePath: fileInfo.projectRelativePath,
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

  internal func collectProjectEnvFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHiddenDirectories: Bool,
    maxFiles: Int,
    maxKeysPerFile: Int,
    maxBytesPerFile: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    envFiles: inout [ProjectEnvFileInfo],
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

      let resolved = try projectScope.resolvedProjectURLPreservingFinalSymlink(child.path)
      let info = try projectScope.fileInfo(url: resolved)
      if info.type == "directory" && !info.isSymlink {
        guard currentDepth < maxDepth else {
          continue
        }
        guard includeHiddenDirectories || !child.lastPathComponent.hasPrefix(".") else {
          continue
        }
        try collectProjectEnvFiles(
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
        try parseProjectEnvFile(
          url: resolved,
          info: info,
          maxKeysPerFile: maxKeysPerFile,
          maxBytesPerFile: maxBytesPerFile
        ))
    }
  }

  internal func parseProjectEnvFile(
    url: URL,
    info: FileInfo,
    maxKeysPerFile: Int,
    maxBytesPerFile: Int
  ) throws -> ProjectEnvFileInfo {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let fileTruncated = data.count > maxBytesPerFile
    let limitedData = fileTruncated ? Data(data.prefix(maxBytesPerFile)) : data
    guard !limitedData.contains(0) else {
      return ProjectEnvFileInfo(
        path: info.path,
        projectRelativePath: info.projectRelativePath,
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
      return ProjectEnvFileInfo(
        path: info.path,
        projectRelativePath: info.projectRelativePath,
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

    var keys: [ProjectEnvKeyInfo] = []
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

    return ProjectEnvFileInfo(
      path: info.path,
      projectRelativePath: info.projectRelativePath,
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
      ProjectEnvKeyInfo(
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

  internal func collectProjectDependencyFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    dependencyFiles: inout [ProjectDependencyFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

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
          ProjectDependencyFileInfo(
            info: info,
            ecosystem: descriptor.ecosystem,
            role: descriptor.role
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectDependencyFiles(
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

  internal func collectProjectRootDependencyFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    dependencyFiles: inout [ProjectDependencyFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

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
          ProjectDependencyFileInfo(
            info: info,
            ecosystem: descriptor.ecosystem,
            role: descriptor.role
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectRootDependencyFiles(
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

  internal func dependencyFileDescriptor(for name: String) -> ProjectDependencyFileDescriptor? {
    if let descriptor = Self.dependencyFileDescriptors.first(where: { $0.name == name }) {
      return descriptor
    }

    let lowercased = name.lowercased()
    if lowercased.hasPrefix("requirements-"), lowercased.hasSuffix(".txt") {
      return ProjectDependencyFileDescriptor(
        name: name,
        ecosystem: "python",
        role: "requirements"
      )
    }
    return nil
  }

  internal func groupedProjectRoots(
    from dependencyFiles: [ProjectDependencyFileInfo]
  ) -> [ProjectRootInfo] {
    var grouped: [String: [ProjectDependencyFileInfo]] = [:]
    for dependencyFile in dependencyFiles {
      let directory = (dependencyFile.info.projectRelativePath as NSString)
        .deletingLastPathComponent
      let normalizedDirectory = directory.isEmpty || directory == "." ? "." : directory
      grouped[normalizedDirectory, default: []].append(dependencyFile)
    }

    return grouped.map { directory, files in
      let sortedFiles = files.sorted {
        $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
          == .orderedAscending
      }
      let ecosystems = Array(Set(sortedFiles.map(\.ecosystem))).sorted()
      let manifestFiles = sortedFiles.filter { $0.role == "manifest" || $0.role == "requirements" }
      let lockFiles = sortedFiles.filter { $0.role == "lock" }
      let checksumFiles = sortedFiles.filter { $0.role == "checksum" }
      return ProjectRootInfo(
        path: projectRootAbsolutePath(directory),
        projectRelativePath: directory,
        ecosystems: ecosystems,
        manifestFiles: manifestFiles.map(\.info.projectRelativePath),
        lockFiles: lockFiles.map(\.info.projectRelativePath),
        checksumFiles: checksumFiles.map(\.info.projectRelativePath),
        dependencyFiles: sortedFiles.map {
          ProjectRootDependencyFileInfo(
            projectRelativePath: $0.info.projectRelativePath,
            name: ($0.info.projectRelativePath as NSString).lastPathComponent,
            ecosystem: $0.ecosystem,
            role: $0.role
          )
        },
        isProjectRoot: directory == "."
      )
    }
    .sorted {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }
  }

  private func projectRootAbsolutePath(_ projectRelativePath: String) -> String {
    if projectRelativePath == "." {
      return configuration.projectDirectory.standardizedFileURL.path
    }
    return configuration.projectDirectory
      .appendingPathComponent(projectRelativePath)
      .standardizedFileURL
      .path
  }

  internal func collectProjectDocumentationFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    documentationFiles: inout [ProjectDocumentationFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = documentationDescriptor(for: info.projectRelativePath)
      {
        guard documentationFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        documentationFiles.append(
          ProjectDocumentationFileInfo(
            info: info,
            category: descriptor.category,
            source: descriptor.source
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectDocumentationFiles(
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

  internal func documentationDescriptor(for projectRelativePath: String)
    -> ProjectDocumentationDescriptor?
  {
    let name = (projectRelativePath as NSString).lastPathComponent
    let baseName = (name as NSString).deletingPathExtension.lowercased()
    let lowercasedName = name.lowercased()

    if let descriptor = Self.documentationFileDescriptors[lowercasedName] {
      return descriptor
    }
    if let descriptor = Self.documentationFileDescriptors[baseName] {
      return descriptor
    }
    if lowercasedName.hasPrefix("readme.") {
      return ProjectDocumentationDescriptor(category: "overview", source: "filename")
    }
    if lowercasedName.hasPrefix("changelog.") || lowercasedName.hasPrefix("changes.") {
      return ProjectDocumentationDescriptor(category: "changelog", source: "filename")
    }
    if lowercasedName.hasPrefix("license.") || lowercasedName.hasPrefix("licence.") {
      return ProjectDocumentationDescriptor(category: "license", source: "filename")
    }

    if isDocumentationDirectoryPath(projectRelativePath),
      isDocumentationFileExtension((name as NSString).pathExtension.lowercased())
    {
      return ProjectDocumentationDescriptor(
        category: "documentation", source: "documentation_directory")
    }

    return nil
  }

  internal func collectProjectAgentFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    agentFiles: inout [ProjectAgentFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = agentFileDescriptor(for: info.projectRelativePath)
      {
        guard agentFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        agentFiles.append(
          ProjectAgentFileInfo(
            info: info,
            kind: descriptor.kind,
            source: descriptor.source
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        guard !Self.agentFileScanSkippedDirectoryNames.contains(name) else {
          continue
        }
        try collectProjectAgentFiles(
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

  internal func agentFileDescriptor(for projectRelativePath: String)
    -> ProjectAgentFileDescriptor?
  {
    let normalized = projectRelativePath.replacingOccurrences(of: "\\", with: "/")
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
      return ProjectAgentFileDescriptor(kind: "cursor_rule", source: "cursor_rules_directory")
    }

    if lowercasedPath.hasPrefix(".windsurf/rules/")
      || lowercasedPath.contains("/.windsurf/rules/"),
      lowercasedName.hasSuffix(".md")
    {
      return ProjectAgentFileDescriptor(
        kind: "windsurf_rule",
        source: "windsurf_rules_directory"
      )
    }

    if lowercasedName == "skill.md",
      lowercasedPath.hasPrefix("skills/") || lowercasedPath.contains("/skills/")
    {
      return ProjectAgentFileDescriptor(kind: "codex_skill", source: "skills_directory")
    }

    return nil
  }

  internal func collectProjectInstructionFiles(
    directory: URL,
    scopeProjectRelativePath: String,
    includeContent: Bool,
    maxBytesPerFile: Int,
    maxResults: Int,
    seenPaths: inout Set<String>,
    files: inout [ProjectInstructionFileInfo],
    resultTruncated: inout Bool,
    applyOrder: inout Int
  ) throws {
    for filename in Self.scopedInstructionFilenames {
      try appendProjectInstructionFile(
        candidate: directory.appendingPathComponent(filename),
        scopeProjectRelativePath: scopeProjectRelativePath,
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

    try appendProjectInstructionFile(
      candidate: directory.appendingPathComponent(".github/copilot-instructions.md"),
      scopeProjectRelativePath: scopeProjectRelativePath,
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
        try appendProjectInstructionFile(
          candidate: child,
          scopeProjectRelativePath: scopeProjectRelativePath,
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

  private func appendProjectInstructionFile(
    candidate: URL,
    scopeProjectRelativePath: String,
    includeContent: Bool,
    maxBytesPerFile: Int,
    maxResults: Int,
    seenPaths: inout Set<String>,
    files: inout [ProjectInstructionFileInfo],
    resultTruncated: inout Bool,
    applyOrder: inout Int
  ) throws {
    guard !resultTruncated else {
      return
    }
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      return
    }

    let candidateProjectRelativePath = projectScope.projectRelativePathPreservingSymlinks(
      candidate)
    let resolved = try projectScope.resolvedProjectURL(candidateProjectRelativePath)
    let info = try projectScope.fileInfo(url: resolved)
    guard info.type == "file" else {
      return
    }
    guard seenPaths.insert(info.projectRelativePath).inserted else {
      return
    }
    guard
      let descriptor =
        agentFileDescriptor(for: candidateProjectRelativePath)
        ?? agentFileDescriptor(for: info.projectRelativePath)
    else {
      return
    }
    guard files.count < maxResults else {
      resultTruncated = true
      return
    }

    let content =
      includeContent
      ? try readProjectInstructionContent(url: resolved, maxBytes: maxBytesPerFile) : nil
    files.append(
      ProjectInstructionFileInfo(
        info: info,
        kind: descriptor.kind,
        source: descriptor.source,
        scopeProjectRelativePath: scopeProjectRelativePath,
        applyOrder: applyOrder,
        content: content
      ))
    applyOrder += 1
  }

  private func readProjectInstructionContent(url: URL, maxBytes: Int) throws
    -> ProjectInstructionContent
  {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let limitedData = truncated ? Data(data.prefix(maxBytes)) : data
    let content = String(data: limitedData, encoding: .utf8)
    return ProjectInstructionContent(
      content: content,
      bytesRead: limitedData.count,
      truncated: truncated,
      validUTF8: content != nil
    )
  }

  private func isDocumentationDirectoryPath(_ projectRelativePath: String) -> Bool {
    projectRelativePath.split(separator: "/").dropLast().contains { component in
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

  internal func collectProjectTestFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    testFiles: inout [ProjectTestFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = testFileDescriptor(for: info.projectRelativePath) {
        guard testFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        testFiles.append(
          ProjectTestFileInfo(
            info: info,
            language: descriptor.language,
            matchSource: descriptor.matchSource,
            style: descriptor.style
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectTestFiles(
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

  internal func testFileDescriptor(for projectRelativePath: String)
    -> ProjectTestFileDescriptor?
  {
    let name = (projectRelativePath as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    guard let language = Self.testFileExtensions[ext] else {
      return nil
    }

    let stem = (name as NSString).deletingPathExtension
    let lowercasedName = name.lowercased()
    let lowercasedStem = stem.lowercased()
    let components = projectRelativePath.split(separator: "/").dropLast().map {
      $0.lowercased()
    }

    if components.contains(where: { Self.testDirectoryNames.contains($0) }) {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "test_directory",
        style: "directory"
      )
    }

    if lowercasedName.contains(".test.") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "dot_test"
      )
    }
    if lowercasedName.contains(".spec.") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "dot_spec"
      )
    }
    if lowercasedStem.hasPrefix("test_") || lowercasedStem.hasPrefix("test-") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "test_prefix"
      )
    }
    if lowercasedStem.hasSuffix("_test") || lowercasedStem.hasSuffix("-test") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "test_suffix"
      )
    }
    if lowercasedStem.hasSuffix("_spec") || lowercasedStem.hasSuffix("-spec") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "spec_suffix"
      )
    }
    if stem.hasSuffix("Test") || stem.hasSuffix("Tests") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "camel_test_suffix"
      )
    }
    if stem.hasSuffix("Spec") || stem.hasSuffix("Specs") {
      return ProjectTestFileDescriptor(
        language: language,
        matchSource: "filename_pattern",
        style: "camel_spec_suffix"
      )
    }

    return nil
  }

  internal func collectProjectCIFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    ciFiles: inout [ProjectCIFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.ciSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = ciFileDescriptor(for: info.projectRelativePath) {
        guard ciFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        ciFiles.append(
          ProjectCIFileInfo(
            info: info,
            provider: descriptor.provider,
            category: descriptor.category,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectCIFiles(
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

  internal func ciFileDescriptor(for projectRelativePath: String) -> ProjectCIFileDescriptor? {
    let components = projectRelativePath.split(separator: "/").map { $0.lowercased() }
    let name = components.last ?? ""
    let ext = ((name as NSString).pathExtension).lowercased()

    if ciWorkflowPath(
      components, marker: ".github", folder: "workflows", extensions: Set(["yml", "yaml"]))
    {
      return ProjectCIFileDescriptor(
        provider: "github_actions",
        category: "workflow",
        matchSource: "workflow_directory"
      )
    }
    if ciWorkflowPath(
      components, marker: ".gitea", folder: "workflows", extensions: Set(["yml", "yaml"]))
    {
      return ProjectCIFileDescriptor(
        provider: "gitea_actions",
        category: "workflow",
        matchSource: "workflow_directory"
      )
    }
    if ciWorkflowPath(
      components, marker: ".forgejo", folder: "workflows", extensions: Set(["yml", "yaml"]))
    {
      return ProjectCIFileDescriptor(
        provider: "forgejo_actions",
        category: "workflow",
        matchSource: "workflow_directory"
      )
    }

    guard Self.ciFileExtensions.contains(ext) || name == "jenkinsfile" else {
      return nil
    }

    if name == ".gitlab-ci.yml" || name == ".gitlab-ci.yaml" {
      return ProjectCIFileDescriptor(
        provider: "gitlab_ci", category: "pipeline", matchSource: "filename")
    }
    if name == "jenkinsfile" {
      return ProjectCIFileDescriptor(
        provider: "jenkins", category: "pipeline", matchSource: "filename")
    }
    if name == "azure-pipelines.yml" || name == "azure-pipelines.yaml" {
      return ProjectCIFileDescriptor(
        provider: "azure_pipelines", category: "pipeline", matchSource: "filename")
    }
    if name == "bitrise.yml" || name == "bitrise.yaml" {
      return ProjectCIFileDescriptor(
        provider: "bitrise", category: "pipeline", matchSource: "filename")
    }
    if name == "appveyor.yml" || name == "appveyor.yaml" {
      return ProjectCIFileDescriptor(
        provider: "appveyor", category: "pipeline", matchSource: "filename")
    }
    if name == ".travis.yml" || name == ".travis.yaml" {
      return ProjectCIFileDescriptor(
        provider: "travis_ci", category: "pipeline", matchSource: "filename")
    }
    if name == ".drone.yml" || name == ".drone.yaml" {
      return ProjectCIFileDescriptor(
        provider: "drone", category: "pipeline", matchSource: "filename")
    }
    if name == ".woodpecker.yml" || name == ".woodpecker.yaml" {
      return ProjectCIFileDescriptor(
        provider: "woodpecker", category: "pipeline", matchSource: "filename")
    }
    if name == ".cirrus.yml" || name == ".cirrus.yaml" {
      return ProjectCIFileDescriptor(
        provider: "cirrus_ci", category: "pipeline", matchSource: "filename")
    }
    if name == "cloudbuild.yml" || name == "cloudbuild.yaml" {
      return ProjectCIFileDescriptor(
        provider: "google_cloud_build", category: "pipeline", matchSource: "filename")
    }
    if name == "buildspec.yml" || name == "buildspec.yaml" {
      return ProjectCIFileDescriptor(
        provider: "aws_codebuild", category: "pipeline", matchSource: "filename")
    }
    if name == "codemagic.yaml" || name == "codemagic.yml" {
      return ProjectCIFileDescriptor(
        provider: "codemagic", category: "pipeline", matchSource: "filename")
    }

    if components.count >= 2, components[components.count - 2] == ".circleci",
      name == "config.yml" || name == "config.yaml"
    {
      return ProjectCIFileDescriptor(
        provider: "circleci", category: "pipeline", matchSource: "config_directory")
    }
    if components.count >= 2, components[components.count - 2] == ".buildkite",
      ext == "yml" || ext == "yaml"
    {
      return ProjectCIFileDescriptor(
        provider: "buildkite", category: "pipeline", matchSource: "config_directory")
    }
    if components.count >= 2, components[components.count - 2] == ".semaphore",
      name == "semaphore.yml" || name == "semaphore.yaml"
    {
      return ProjectCIFileDescriptor(
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

  internal func collectProjectInfraFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    infraFiles: inout [ProjectInfraFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.infraSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden,
        !Self.infraAlwaysIncludedDirectoryNames.contains(lowercasedName)
      {
        continue
      }

      if info.type == "file",
        let descriptor = infraFileDescriptor(for: info.projectRelativePath)
      {
        guard infraFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        infraFiles.append(
          ProjectInfraFileInfo(
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
        try collectProjectInfraFiles(
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

  internal func infraFileDescriptor(for projectRelativePath: String)
    -> ProjectInfraFileDescriptor?
  {
    let name = (projectRelativePath as NSString).lastPathComponent.lowercased()
    let ext = (projectRelativePath as NSString).pathExtension.lowercased()

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
      isInInfraDirectory(projectRelativePath)
    else {
      return nil
    }

    var descriptor = directoryScopedInfraDescriptor(
      projectRelativePath: projectRelativePath,
      ext: ext
    )
    descriptor.fileExtension = ext
    return descriptor
  }

  private func infraFilenamePatternDescriptor(name: String, ext: String)
    -> ProjectInfraFileDescriptor?
  {
    if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
      return ProjectInfraFileDescriptor(
        category: "container",
        provider: "docker",
        kind: "image_build",
        format: "dockerfile",
        matchSource: "filename_pattern"
      )
    }
    if name.hasPrefix("containerfile.") || name.hasSuffix(".containerfile") {
      return ProjectInfraFileDescriptor(
        category: "container",
        provider: "containerfile",
        kind: "image_build",
        format: "containerfile",
        matchSource: "filename_pattern"
      )
    }
    if (ext == "yaml" || ext == "yml" || ext == "json") && name.contains("compose") {
      return ProjectInfraFileDescriptor(
        category: "container_orchestration",
        provider: "docker_compose",
        kind: "compose_file",
        format: ext == "json" ? "json" : "yaml",
        matchSource: "filename_pattern",
        jsonReadable: ext == "json"
      )
    }
    if name.hasSuffix(".tf.json") || name.hasSuffix(".tfvars.json") {
      return ProjectInfraFileDescriptor(
        category: "infrastructure_as_code",
        provider: "terraform",
        kind: name.hasSuffix(".tfvars.json") ? "variables" : "module",
        format: "json",
        matchSource: "filename_pattern",
        jsonReadable: true
      )
    }
    if name.hasSuffix(".pkr.hcl") {
      return ProjectInfraFileDescriptor(
        category: "infrastructure_as_code",
        provider: "packer",
        kind: "template",
        format: "hcl",
        matchSource: "filename_pattern"
      )
    }
    if name.hasSuffix(".nomad") || name.hasSuffix(".nomad.hcl") {
      return ProjectInfraFileDescriptor(
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
    projectRelativePath: String,
    ext: String
  ) -> ProjectInfraFileDescriptor {
    let components = projectRelativePath.split(separator: "/").map { $0.lowercased() }
    let format = infraFormat(for: ext)

    if components.contains(".devcontainer") || components.contains("devcontainer") {
      return ProjectInfraFileDescriptor(
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
      return ProjectInfraFileDescriptor(
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
      return ProjectInfraFileDescriptor(
        category: "orchestration",
        provider: "kubernetes",
        kind: "manifest",
        format: format,
        matchSource: "infra_directory",
        jsonReadable: ext == "json"
      )
    }
    if components.contains("terraform") {
      return ProjectInfraFileDescriptor(
        category: "infrastructure_as_code",
        provider: "terraform",
        kind: "module",
        format: format,
        matchSource: "infra_directory",
        jsonReadable: ext == "json",
        tomlReadable: ext == "toml"
      )
    }

    return ProjectInfraFileDescriptor(
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

  private func isInInfraDirectory(_ projectRelativePath: String) -> Bool {
    let directory = (projectRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.infraDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectProjectConfigFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    configFiles: inout [ProjectConfigFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.configSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = configFileDescriptor(for: info.projectRelativePath) {
        guard configFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        configFiles.append(
          ProjectConfigFileInfo(
            info: info,
            tool: descriptor.tool,
            category: descriptor.category,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectConfigFiles(
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

  internal func configFileDescriptor(for projectRelativePath: String)
    -> ProjectConfigFileDescriptor?
  {
    let components = projectRelativePath.split(separator: "/").map { $0.lowercased() }
    let name = components.last ?? ""

    if let descriptor = Self.configExactFileDescriptors[String(name)] {
      return descriptor
    }

    if components.count >= 2, components[components.count - 2] == ".vscode" {
      switch name {
      case "settings.json", "extensions.json", "tasks.json", "launch.json":
        return ProjectConfigFileDescriptor(
          tool: "vscode", category: "editor", matchSource: "config_directory")
      default:
        break
      }
    }

    if name.hasPrefix("tsconfig."), name.hasSuffix(".json") {
      return ProjectConfigFileDescriptor(
        tool: "typescript", category: "compiler", matchSource: "filename_pattern")
    }
    if name.hasPrefix("eslint.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "eslint", category: "linter", matchSource: "filename_pattern")
    }
    if name.hasPrefix("prettier.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "prettier", category: "formatter", matchSource: "filename_pattern")
    }
    if name.hasPrefix("stylelint.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "stylelint", category: "linter", matchSource: "filename_pattern")
    }
    if name.hasPrefix("babel.config."), configScriptOrJSONExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "babel", category: "transpiler", matchSource: "filename_pattern")
    }
    if name.hasPrefix(".babelrc."), configScriptOrJSONExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "babel", category: "transpiler", matchSource: "filename_pattern")
    }
    if name.hasPrefix("postcss.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "postcss", category: "css_processor", matchSource: "filename_pattern")
    }
    if name.hasPrefix("tailwind.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "tailwind", category: "styling", matchSource: "filename_pattern")
    }
    if name.hasPrefix("vite.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "vite", category: "build_tool", matchSource: "filename_pattern")
    }
    if name.hasPrefix("vitest.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "vitest", category: "test_runner", matchSource: "filename_pattern")
    }
    if name.hasPrefix("webpack.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "webpack", category: "build_tool", matchSource: "filename_pattern")
    }
    if name.hasPrefix("rollup.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "rollup", category: "build_tool", matchSource: "filename_pattern")
    }
    if name.hasPrefix("next.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "next", category: "framework", matchSource: "filename_pattern")
    }
    if name.hasPrefix("nuxt.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "nuxt", category: "framework", matchSource: "filename_pattern")
    }
    if name.hasPrefix("svelte.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "svelte", category: "framework", matchSource: "filename_pattern")
    }
    if name.hasPrefix("astro.config."), configScriptExtension(String(name)) {
      return ProjectConfigFileDescriptor(
        tool: "astro", category: "framework", matchSource: "filename_pattern")
    }
    if name == "turbo.json" {
      return ProjectConfigFileDescriptor(
        tool: "turbo", category: "monorepo", matchSource: "filename")
    }
    if name == "nx.json" {
      return ProjectConfigFileDescriptor(
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

  internal func collectProjectIgnoreFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    ignoreFiles: inout [ProjectIgnoreFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.configSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = ignoreFileDescriptor(for: info.projectRelativePath) {
        guard ignoreFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        ignoreFiles.append(
          ProjectIgnoreFileInfo(
            info: info,
            provider: descriptor.provider,
            category: descriptor.category,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectIgnoreFiles(
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

  internal func ignoreFileDescriptor(for projectRelativePath: String)
    -> ProjectIgnoreFileDescriptor?
  {
    let components = projectRelativePath.split(separator: "/").map { $0.lowercased() }
    if components.count >= 3,
      components[components.count - 3] == ".git",
      components[components.count - 2] == "info",
      components[components.count - 1] == "exclude"
    {
      return ProjectIgnoreFileDescriptor(
        provider: "git",
        category: "source_control_ignore",
        matchSource: "git_info_exclude"
      )
    }

    let name = components.last.map { String($0) } ?? ""
    return Self.ignoreFileDescriptors[name]
  }

  internal func collectProjectAssetFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    assetFiles: inout [ProjectAssetFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file", let descriptor = assetFileDescriptor(for: info.projectRelativePath) {
        guard assetFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        assetFiles.append(
          ProjectAssetFileInfo(
            info: info,
            category: descriptor.category,
            subtype: descriptor.subtype,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectAssetFiles(
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

  internal func assetFileDescriptor(for projectRelativePath: String)
    -> ProjectAssetFileDescriptor?
  {
    let ext = (projectRelativePath as NSString).pathExtension.lowercased()
    guard var descriptor = Self.assetFileExtensions[ext] else {
      return nil
    }
    descriptor.fileExtension = ext
    return descriptor
  }

  internal func collectProjectArchiveFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    archiveFiles: inout [ProjectArchiveFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.archiveSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = archiveFileDescriptor(for: info.projectRelativePath)
      {
        guard archiveFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        archiveFiles.append(
          ProjectArchiveFileInfo(
            info: info,
            category: descriptor.category,
            format: descriptor.format,
            fileExtension: descriptor.fileExtension,
            listSupported: descriptor.listSupported
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectArchiveFiles(
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

  internal func archiveFileDescriptor(for projectRelativePath: String)
    -> ProjectArchiveFileDescriptor?
  {
    let name = (projectRelativePath as NSString).lastPathComponent.lowercased()
    return Self.archiveFileDescriptors.first { name.hasSuffix($0.suffix) }
  }

  internal func collectProjectLogFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    logFiles: inout [ProjectLogFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.logSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = logFileDescriptor(for: info.projectRelativePath)
      {
        guard logFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        logFiles.append(
          ProjectLogFileInfo(
            info: info,
            category: descriptor.category,
            kind: descriptor.kind,
            matchSource: descriptor.matchSource,
            fileExtension: descriptor.fileExtension
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectLogFiles(
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

  internal func logFileDescriptor(for projectRelativePath: String) -> ProjectLogFileDescriptor? {
    let name = (projectRelativePath as NSString).lastPathComponent.lowercased()
    if var descriptor = Self.logExactFileDescriptors[name] {
      descriptor.fileExtension = (projectRelativePath as NSString).pathExtension.lowercased()
      return descriptor
    }

    let ext = (projectRelativePath as NSString).pathExtension.lowercased()
    if var descriptor = Self.logFileExtensions[ext] {
      descriptor.fileExtension = ext
      return descriptor
    }

    if name.contains(".log.") || name.contains(".out.") || name.contains(".err.") {
      return ProjectLogFileDescriptor(
        category: "application_log",
        kind: "rotated",
        matchSource: "rotated_suffix",
        fileExtension: ext
      )
    }

    if isInLogDirectory(projectRelativePath),
      Self.logDirectoryFileExtensions.contains(ext)
    {
      return ProjectLogFileDescriptor(
        category: "application_log",
        kind: "log",
        matchSource: "logs_directory",
        fileExtension: ext
      )
    }

    return nil
  }

  private func isInLogDirectory(_ projectRelativePath: String) -> Bool {
    let directory = (projectRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.logDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectProjectDataFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    dataFiles: inout [ProjectDataFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.dataSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = dataFileDescriptor(for: info.projectRelativePath)
      {
        guard dataFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        dataFiles.append(
          ProjectDataFileInfo(
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
        try collectProjectDataFiles(
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

  internal func dataFileDescriptor(for projectRelativePath: String)
    -> ProjectDataFileDescriptor?
  {
    let ext = (projectRelativePath as NSString).pathExtension.lowercased()
    if var descriptor = Self.dataFileExtensions[ext] {
      descriptor.fileExtension = ext
      return descriptor
    }

    guard Self.directoryScopedDataFileExtensions.contains(ext),
      isInDataDirectory(projectRelativePath),
      var descriptor = Self.directoryScopedDataFileDescriptors[ext]
    else {
      return nil
    }

    descriptor.fileExtension = ext
    return descriptor
  }

  private func isInDataDirectory(_ projectRelativePath: String) -> Bool {
    let directory = (projectRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.dataDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectProjectSchemaFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    schemaFiles: inout [ProjectSchemaFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.schemaSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = schemaFileDescriptor(for: info.projectRelativePath)
      {
        guard schemaFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        schemaFiles.append(
          ProjectSchemaFileInfo(
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
        try collectProjectSchemaFiles(
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

  internal func schemaFileDescriptor(for projectRelativePath: String)
    -> ProjectSchemaFileDescriptor?
  {
    let name = (projectRelativePath as NSString).lastPathComponent.lowercased()
    let ext = (projectRelativePath as NSString).pathExtension.lowercased()

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
      isInSchemaDirectory(projectRelativePath)
    else {
      return nil
    }

    var descriptor = directoryScopedSchemaDescriptor(ext: ext)
    descriptor.fileExtension = ext
    return descriptor
  }

  private func schemaFilenamePatternDescriptor(name: String, ext: String)
    -> ProjectSchemaFileDescriptor?
  {
    guard ["json", "yaml", "yml"].contains(ext) else {
      return nil
    }

    if name.contains("openapi") {
      return ProjectSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "openapi",
        format: ext == "json" ? "json" : "yaml",
        jsonReadable: ext == "json",
        matchSource: "filename_pattern"
      )
    }
    if name.contains("swagger") {
      return ProjectSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "swagger",
        format: ext == "json" ? "json" : "yaml",
        jsonReadable: ext == "json",
        matchSource: "filename_pattern"
      )
    }
    if name.contains("asyncapi") {
      return ProjectSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "asyncapi",
        format: ext == "json" ? "json" : "yaml",
        jsonReadable: ext == "json",
        matchSource: "filename_pattern"
      )
    }
    if name.hasSuffix(".schema.json") {
      return ProjectSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "json_schema",
        format: "json",
        jsonReadable: true,
        matchSource: "filename_pattern"
      )
    }

    return nil
  }

  private func directoryScopedSchemaDescriptor(ext: String) -> ProjectSchemaFileDescriptor {
    switch ext {
    case "json":
      return ProjectSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "json_schema",
        format: "json",
        jsonReadable: true,
        matchSource: "schema_directory"
      )
    case "json5":
      return ProjectSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "json_schema",
        format: "json5",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    case "sql":
      return ProjectSchemaFileDescriptor(
        category: "database_schema",
        schemaKind: "sql_migration",
        format: "sql",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    case "xml":
      return ProjectSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "xml_schema",
        format: "xml",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    case "toml":
      return ProjectSchemaFileDescriptor(
        category: "data_schema",
        schemaKind: "schema_definition",
        format: "toml",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    default:
      return ProjectSchemaFileDescriptor(
        category: "api_contract",
        schemaKind: "schema_definition",
        format: "yaml",
        jsonReadable: false,
        matchSource: "schema_directory"
      )
    }
  }

  private func isInSchemaDirectory(_ projectRelativePath: String) -> Bool {
    let directory = (projectRelativePath as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "." else {
      return false
    }
    return directory.split(separator: "/").contains { component in
      Self.schemaDirectoryNames.contains(component.lowercased())
    }
  }

  internal func collectProjectSourceFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    includeTests: Bool,
    maxResults: Int,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    sourceFiles: inout [ProjectSourceFileInfo],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file",
        let descriptor = sourceFileDescriptor(for: info.projectRelativePath),
        includeTests || testFileDescriptor(for: info.projectRelativePath) == nil
      {
        guard sourceFiles.count < maxResults else {
          resultTruncated = true
          return
        }
        sourceFiles.append(
          ProjectSourceFileInfo(
            info: info,
            language: descriptor.language,
            kind: descriptor.kind,
            matchSource: descriptor.matchSource
          ))
      }

      if info.type == "directory", currentDepth < maxDepth {
        try collectProjectSourceFiles(
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

  internal func collectProjectOutlineItems(
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
    items: inout [ProjectOutlineItem],
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
      let info = try projectScope.fileInfo(url: child)

      if Self.sourceSkippedDirectoryNames.contains(lowercasedName), info.type == "directory" {
        continue
      }
      if name.hasPrefix("."), !includeHidden {
        continue
      }

      if info.type == "file" {
        try appendProjectOutlineItems(
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
        try collectProjectOutlineItems(
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

  internal func appendProjectOutlineItems(
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
    items: inout [ProjectOutlineItem],
    resultTruncated: inout Bool
  ) throws {
    guard !resultTruncated else {
      return
    }
    guard info.type == "file", let language = outlineLanguage(for: url) else {
      return
    }
    guard includeTests || testFileDescriptor(for: info.projectRelativePath) == nil else {
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
        ProjectOutlineItem(
          info: info,
          language: language,
          item: item,
          fileTruncated: fileTruncated
        ))
    }
  }

  internal func sourceFileDescriptor(for projectRelativePath: String)
    -> ProjectSourceFileDescriptor?
  {
    let name = (projectRelativePath as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    guard let descriptor = Self.sourceFileExtensions[ext] else {
      return nil
    }
    return descriptor
  }

  internal func collectProjectCommandManifests(
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
      let info = try projectScope.fileInfo(url: child)

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
        try collectProjectCommandManifests(
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

  internal func parseProjectCommandManifest(
    info: FileInfo,
    maxBytesPerFile: Int
  ) -> ProjectCommandManifestParseResult {
    let url = URL(fileURLWithPath: info.path)
    let name = url.lastPathComponent
    let cwd = (info.projectRelativePath as NSString).deletingLastPathComponent
    let normalizedCWD = cwd == "." ? "" : cwd
    let readResult: ProjectCommandManifestReadResult
    do {
      readResult = try readProjectCommandManifest(url: url, maxBytesPerFile: maxBytesPerFile)
    } catch {
      return ProjectCommandManifestParseResult(
        commands: [],
        errors: [
          ProjectCommandParseError(
            sourceProjectRelativePath: info.projectRelativePath,
            message: error.localizedDescription)
        ],
        fileTruncated: false
      )
    }

    if let parseError = readResult.parseError {
      return ProjectCommandManifestParseResult(
        commands: [],
        errors: [
          ProjectCommandParseError(
            sourceProjectRelativePath: info.projectRelativePath,
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
        cwdProjectRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated
      )
    case "Package.swift":
      return ProjectCommandManifestParseResult(
        commands: swiftPackageCommands(info: info, cwdProjectRelativePath: normalizedCWD),
        errors: [],
        fileTruncated: readResult.fileTruncated
      )
    case "Cargo.toml":
      return parseCargoCommands(
        content: readResult.content,
        info: info,
        cwdProjectRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated
      )
    case "go.mod":
      return parseGoModCommands(
        content: readResult.content,
        info: info,
        cwdProjectRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated
      )
    case "Makefile", "makefile", "GNUmakefile":
      return parseMakefileCommands(
        content: readResult.content,
        info: info,
        cwdProjectRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated,
        executable: "make"
      )
    case "Justfile", "justfile":
      return parseMakefileCommands(
        content: readResult.content,
        info: info,
        cwdProjectRelativePath: normalizedCWD,
        fileTruncated: readResult.fileTruncated,
        executable: "just"
      )
    default:
      return ProjectCommandManifestParseResult(
        commands: [],
        errors: [],
        fileTruncated: readResult.fileTruncated
      )
    }
  }

  private func readProjectCommandManifest(
    url: URL,
    maxBytesPerFile: Int
  ) throws -> ProjectCommandManifestReadResult {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let fileTruncated = data.count > maxBytesPerFile
    let limitedData = fileTruncated ? Data(data.prefix(maxBytesPerFile)) : data
    guard !limitedData.contains(0) else {
      return ProjectCommandManifestReadResult(
        content: "",
        fileTruncated: fileTruncated,
        parseError: "File appears to be binary."
      )
    }
    guard let content = String(data: limitedData, encoding: .utf8) else {
      return ProjectCommandManifestReadResult(
        content: "",
        fileTruncated: fileTruncated,
        parseError: "File is not valid UTF-8."
      )
    }
    return ProjectCommandManifestReadResult(
      content: content,
      fileTruncated: fileTruncated,
      parseError: nil
    )
  }

  private func parsePackageJSONCommands(
    content: String,
    info: FileInfo,
    cwdProjectRelativePath: String,
    fileTruncated: Bool
  ) -> ProjectCommandManifestParseResult {
    let data = Data(content.utf8)
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      return ProjectCommandManifestParseResult(
        commands: [],
        errors: [
          ProjectCommandParseError(
            sourceProjectRelativePath: info.projectRelativePath,
            message: "Unable to parse package.json: \(error.localizedDescription)")
        ],
        fileTruncated: fileTruncated
      )
    }

    guard let object = value.objectValue else {
      return ProjectCommandManifestParseResult(
        commands: [],
        errors: [
          ProjectCommandParseError(
            sourceProjectRelativePath: info.projectRelativePath,
            message: "package.json root is not an object.")
        ],
        fileTruncated: fileTruncated
      )
    }

    let packageManager = nodePackageManager(
      packageManagerField: object["packageManager"]?.stringValue,
      cwdProjectRelativePath: cwdProjectRelativePath
    )
    let scripts = object["scripts"]?.objectValue ?? [:]
    let commands = scripts.keys.sorted().compactMap { scriptName -> ProjectCommandInfo? in
      guard let definition = scripts[scriptName]?.stringValue else {
        return nil
      }
      return commandInfo(
        source: info,
        cwdProjectRelativePath: cwdProjectRelativePath,
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

    return ProjectCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func nodePackageManager(
    packageManagerField: String?,
    cwdProjectRelativePath: String
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

    let directory = projectScope.projectURL(forRelativeDirectory: cwdProjectRelativePath)
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
    cwdProjectRelativePath: String
  ) -> [ProjectCommandInfo] {
    [
      commandInfo(
        source: info,
        cwdProjectRelativePath: cwdProjectRelativePath,
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
        cwdProjectRelativePath: cwdProjectRelativePath,
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
        cwdProjectRelativePath: cwdProjectRelativePath,
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
    cwdProjectRelativePath: String,
    fileTruncated: Bool
  ) -> ProjectCommandManifestParseResult {
    let hasMain = FileManager.default.fileExists(
      atPath: projectScope.projectURL(forRelativeDirectory: cwdProjectRelativePath)
        .appendingPathComponent("src/main.rs").path)
    var commands = [
      commandInfo(
        source: info,
        cwdProjectRelativePath: cwdProjectRelativePath,
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
        cwdProjectRelativePath: cwdProjectRelativePath,
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
          cwdProjectRelativePath: cwdProjectRelativePath,
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
    return ProjectCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func parseGoModCommands(
    content: String,
    info: FileInfo,
    cwdProjectRelativePath: String,
    fileTruncated: Bool
  ) -> ProjectCommandManifestParseResult {
    let moduleName = content.split(separator: "\n", omittingEmptySubsequences: false)
      .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("module ") }
      .map { line in
        String(line.trimmingCharacters(in: .whitespaces).dropFirst("module ".count))
      }

    let commands = [
      commandInfo(
        source: info,
        cwdProjectRelativePath: cwdProjectRelativePath,
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
        cwdProjectRelativePath: cwdProjectRelativePath,
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
        cwdProjectRelativePath: cwdProjectRelativePath,
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

    return ProjectCommandManifestParseResult(
      commands: commands,
      errors: [],
      fileTruncated: fileTruncated
    )
  }

  private func parseMakefileCommands(
    content: String,
    info: FileInfo,
    cwdProjectRelativePath: String,
    fileTruncated: Bool,
    executable: String
  ) -> ProjectCommandManifestParseResult {
    var commands: [ProjectCommandInfo] = []
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
            cwdProjectRelativePath: cwdProjectRelativePath,
            ecosystem: executable == "just" ? "just" : "make",
            kind: "target",
            name: target,
            definition: nil,
            definitionSource: "\(info.projectRelativePath):target",
            suggestedCLIID: executable,
            requiredExecutable: executable,
            argv: [target],
            fileTruncated: fileTruncated
          ))
      }
    }

    return ProjectCommandManifestParseResult(
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
    cwdProjectRelativePath: String,
    ecosystem: String,
    kind: String,
    name: String,
    definition: String?,
    definitionSource: String,
    suggestedCLIID: String,
    requiredExecutable: String,
    argv: [String],
    fileTruncated: Bool
  ) -> ProjectCommandInfo {
    ProjectCommandInfo(
      sourcePath: source.path,
      sourceProjectRelativePath: source.projectRelativePath,
      cwdProjectRelativePath: cwdProjectRelativePath.isEmpty ? "." : cwdProjectRelativePath,
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

internal struct ProjectOutlineItem {
  var info: FileInfo
  var language: String
  var item: FileOutlineItem
  var fileTruncated: Bool

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "language": .string(language),
      "line": .integer(Int64(item.line)),
      "kind": .string(item.kind),
      "level": item.level.map { .integer(Int64($0)) } ?? .null,
      "name": .string(item.name),
      "text": .string(item.text),
      "file_truncated": .bool(fileTruncated),
      "read_context": .object([
        "tool": .string("file.read_context"),
        "path": .string(info.projectRelativePath),
        "line": .integer(Int64(item.line)),
      ]),
      "outline_context": .object([
        "tool": .string("file.outline"),
        "path": .string(info.projectRelativePath),
      ]),
    ])
  }
}

internal struct ProjectDirectoryStatInfo {
  var projectRelativePath: String
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
      "project_relative_path": .string(projectRelativePath),
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

private struct ProjectArtifactDirectoryDescriptor {
  var category: String
  var kind: String
  var cleanupRisk: String
}

internal struct ProjectArtifactDirectoryInfo {
  var info: FileInfo
  var category: String
  var kind: String
  var cleanupRisk: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
        "path": .string(info.projectRelativePath),
      ]),
      "disk_usage_context": .object([
        "tool": .string("file.disk_usage"),
        "path": .string(info.projectRelativePath),
      ]),
      "tree_context": .object([
        "tool": .string("file.tree"),
        "path": .string(info.projectRelativePath),
      ]),
      "directory_stats_context": .object([
        "tool": .string("project.directory_stats"),
        "path": .string(info.projectRelativePath),
      ]),
    ])
  }
}

internal struct ProjectEmptyDirectoryInfo {
  var path: String
  var projectRelativePath: String
  var name: String
  var depth: Int
  var isRoot: Bool
  var modifiedAt: Date?

  var json: JSONValue {
    .object([
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
      "name": .string(name),
      "depth": .integer(Int64(depth)),
      "is_root": .bool(isRoot),
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "child_count": .number(0),
      "project.reveal": .object([
        "tool": .string("project.reveal"),
        "arguments": .object([
          "path": .string(projectRelativePath)
        ]),
      ]),
    ])
  }
}

internal struct ProjectGitChange {
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
      "project_relative_path": .string(path),
      "original_path": originalPath.map(JSONValue.string) ?? .null,
    ])
  }
}

internal struct ProjectFileTypeSummary {
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

internal struct ProjectSymlinkInfo {
  var path: String
  var projectRelativePath: String
  var destination: String
  var targetAbsolutePath: String
  var targetExists: Bool
  var targetIsDirectory: Bool
  var targetProjectContained: Bool

  var json: JSONValue {
    .object([
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
      "destination": .string(destination),
      "target_absolute_path": .string(targetAbsolutePath),
      "target_exists": .bool(targetExists),
      "target_is_directory": .bool(targetIsDirectory),
      "target_project_contained": .bool(targetProjectContained),
      "broken": .bool(!targetExists),
    ])
  }
}

internal struct ProjectTodoMatch {
  var marker: String
  var path: String
  var projectRelativePath: String
  var line: Int
  var column: Int
  var preview: String
  var fileTruncated: Bool

  var json: JSONValue {
    .object([
      "marker": .string(marker),
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
      "line": .integer(Int64(line)),
      "column": .integer(Int64(column)),
      "preview": .string(preview),
      "file_truncated": .bool(fileTruncated),
    ])
  }
}

internal struct ProjectEnvFileInfo {
  var path: String
  var projectRelativePath: String
  var sizeBytes: Int64?
  var modifiedAt: Date?
  var bytesScanned: Int
  var fileTruncated: Bool
  var keysTruncated: Bool
  var invalidLineCount: Int
  var parseError: String?
  var keys: [ProjectEnvKeyInfo]

  var json: JSONValue {
    .object([
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
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

internal struct ProjectEnvKeyInfo {
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
  case key(ProjectEnvKeyInfo)
}

internal struct ProjectDependencyFileDescriptor {
  var name: String
  var ecosystem: String
  var role: String
}

internal struct ProjectDependencyFileInfo {
  var info: FileInfo
  var ecosystem: String
  var role: String

  var xmlReadable: Bool {
    ((info.projectRelativePath as NSString).lastPathComponent).lowercased().hasSuffix(".xml")
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
          "path": .string(info.projectRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct ProjectRootDependencyFileInfo {
  var projectRelativePath: String
  var name: String
  var ecosystem: String
  var role: String

  var json: JSONValue {
    .object([
      "project_relative_path": .string(projectRelativePath),
      "name": .string(name),
      "ecosystem": .string(ecosystem),
      "role": .string(role),
    ])
  }
}

internal struct ProjectRootInfo {
  var path: String
  var projectRelativePath: String
  var ecosystems: [String]
  var manifestFiles: [String]
  var lockFiles: [String]
  var checksumFiles: [String]
  var dependencyFiles: [ProjectRootDependencyFileInfo]
  var isProjectRoot: Bool

  var json: JSONValue {
    .object([
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
      "ecosystems": .array(ecosystems.map(JSONValue.string)),
      "manifest_files": .array(manifestFiles.map(JSONValue.string)),
      "lock_files": .array(lockFiles.map(JSONValue.string)),
      "checksum_files": .array(checksumFiles.map(JSONValue.string)),
      "dependency_file_count": .integer(Int64(dependencyFiles.count)),
      "dependency_files": .array(dependencyFiles.map(\.json)),
      "is_project_root": .bool(isProjectRoot),
    ])
  }
}

internal struct ProjectDocumentationDescriptor {
  var category: String
  var source: String
}

internal struct ProjectDocumentationFileInfo {
  var info: FileInfo
  var category: String
  var source: String

  var isMarkdown: Bool {
    let ext = (info.projectRelativePath as NSString).pathExtension.lowercased()
    return ["md", "markdown", "mdown", "mdx"].contains(ext)
      || (info.projectRelativePath as NSString).lastPathComponent.lowercased() == "readme"
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
      "category": .string(category),
      "source": .string(source),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "markdown_links_context": isMarkdown
        ? .object([
          "tool": .string("markdown.links"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "markdown_link_check_context": isMarkdown
        ? .object([
          "tool": .string("markdown.link_check"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct ProjectAgentFileDescriptor {
  var kind: String
  var source: String
}

internal struct ProjectAgentFileInfo {
  var info: FileInfo
  var kind: String
  var source: String

  var scopeProjectRelativePath: String {
    let directory = (info.projectRelativePath as NSString).deletingLastPathComponent
    return directory.isEmpty ? "." : directory
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
      "kind": .string(kind),
      "source": .string(source),
      "scope_project_relative_path": .string(scopeProjectRelativePath),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "read_context": .object([
        "tool": .string("file.read"),
        "path": .string(info.projectRelativePath),
      ]),
    ])
  }
}

internal struct ProjectInstructionContent {
  var content: String?
  var bytesRead: Int
  var truncated: Bool
  var validUTF8: Bool
}

internal struct ProjectInstructionFileInfo {
  var info: FileInfo
  var kind: String
  var source: String
  var scopeProjectRelativePath: String
  var applyOrder: Int
  var content: ProjectInstructionContent?

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
      "kind": .string(kind),
      "source": .string(source),
      "scope_project_relative_path": .string(scopeProjectRelativePath),
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
        "path": .string(info.projectRelativePath),
      ]),
    ])
  }
}

internal struct ProjectTestFileDescriptor {
  var language: String
  var matchSource: String
  var style: String
}

internal struct ProjectTestFileInfo {
  var info: FileInfo
  var language: String
  var matchSource: String
  var style: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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

internal struct ProjectCIFileDescriptor {
  var provider: String
  var category: String
  var matchSource: String
}

internal struct ProjectCIFileInfo {
  var info: FileInfo
  var provider: String
  var category: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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

internal struct ProjectInfraFileDescriptor {
  var category: String
  var provider: String
  var kind: String
  var format: String
  var matchSource: String
  var jsonReadable: Bool = false
  var tomlReadable: Bool = false
  var fileExtension: String = ""
}

internal struct ProjectInfraFileInfo {
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
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
        "path": .string(info.projectRelativePath),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.projectRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.projectRelativePath),
      ]),
      "json_context": jsonReadable
        ? .object([
          "tool": .string("json.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "toml_context": tomlReadable
        ? .object([
          "tool": .string("toml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "yaml_context": yamlReadable
        ? .object([
          "tool": .string("yaml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct ProjectConfigFileDescriptor {
  var tool: String
  var category: String
  var matchSource: String
}

internal struct ProjectConfigFileInfo {
  var info: FileInfo
  var tool: String
  var category: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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

internal struct ProjectIgnoreFileDescriptor {
  var provider: String
  var category: String
  var matchSource: String
}

internal struct ProjectIgnoreFileInfo {
  var info: FileInfo
  var provider: String
  var category: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
      "provider": .string(provider),
      "category": .string(category),
      "match_source": .string(matchSource),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "read_context": .object([
        "tool": .string("file.read"),
        "path": .string(info.projectRelativePath),
      ]),
    ])
  }
}

internal struct ProjectAssetFileDescriptor {
  var category: String
  var subtype: String
  var fileExtension: String = ""
}

internal struct ProjectAssetFileInfo {
  var info: FileInfo
  var category: String
  var subtype: String
  var fileExtension: String

  var json: JSONValue {
    var object: [String: JSONValue] = [
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
      "extension": .string(fileExtension),
      "category": .string(category),
      "subtype": .string(subtype),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.projectRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.projectRelativePath),
      ]),
    ]
    if category == "image" {
      object["image_info_context"] = .object([
        "tool": .string("image.info"),
        "path": .string(info.projectRelativePath),
      ])
    }
    if category == "document", subtype == "pdf" {
      object["pdf_info_context"] = .object([
        "tool": .string("pdf.info"),
        "path": .string(info.projectRelativePath),
      ])
      object["pdf_text_context"] = .object([
        "tool": .string("pdf.text"),
        "path": .string(info.projectRelativePath),
      ])
    }
    if category == "audio" || category == "video" {
      object["media_info_context"] = .object([
        "tool": .string("media.info"),
        "path": .string(info.projectRelativePath),
      ])
    }
    return .object(object)
  }
}

internal struct ProjectArchiveFileDescriptor {
  var suffix: String
  var fileExtension: String
  var category: String
  var format: String
  var listSupported: Bool
}

internal struct ProjectArchiveFileInfo {
  var info: FileInfo
  var category: String
  var format: String
  var fileExtension: String
  var listSupported: Bool

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
        "path": .string(info.projectRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.projectRelativePath),
      ]),
      "list_context": listSupported
        ? .object([
          "tool": .string("archive.list"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "read_file_context": listSupported
        ? .object([
          "tool": .string("archive.read_file"),
          "path": .string(info.projectRelativePath),
          "entry": .null,
        ])
        : .null,
    ])
  }
}

internal struct ProjectLogFileDescriptor {
  var category: String
  var kind: String
  var matchSource: String
  var fileExtension: String = ""
}

internal struct ProjectLogFileInfo {
  var info: FileInfo
  var category: String
  var kind: String
  var matchSource: String
  var fileExtension: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
        "path": .string(info.projectRelativePath),
      ]),
      "search_context": .object([
        "tool": .string("file.search"),
        "path": .string(info.projectRelativePath),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.projectRelativePath),
      ]),
    ])
  }
}

internal struct ProjectDataFileDescriptor {
  var category: String
  var format: String
  var textReadable: Bool
  var jsonReadable: Bool
  var jsonLinesReadable: Bool = false
  var matchSource: String = "extension"
  var fileExtension: String = ""
}

internal struct ProjectDataFileInfo {
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
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
        "path": .string(info.projectRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.projectRelativePath),
      ]),
      "read_lines_context": textReadable
        ? .object([
          "tool": .string("file.read_lines"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "tail_context": textReadable
        ? .object([
          "tool": .string("file.tail"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "count_context": textReadable
        ? .object([
          "tool": .string("file.count"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "json_context": jsonReadable
        ? .object([
          "tool": .string("json.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "jsonl_context": jsonLinesReadable
        ? .object([
          "tool": .string("jsonl.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "yaml_context": yamlReadable
        ? .object([
          "tool": .string("yaml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct ProjectSchemaFileDescriptor {
  var category: String
  var schemaKind: String
  var format: String
  var jsonReadable: Bool
  var matchSource: String = "extension"
  var fileExtension: String = ""
}

internal struct ProjectSchemaFileInfo {
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
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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
        "path": .string(info.projectRelativePath),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "path": .string(info.projectRelativePath),
      ]),
      "metadata_context": .object([
        "tool": .string("file.metadata"),
        "path": .string(info.projectRelativePath),
      ]),
      "json_context": jsonReadable
        ? .object([
          "tool": .string("json.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "yaml_context": yamlReadable
        ? .object([
          "tool": .string("yaml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
      "xml_context": xmlReadable
        ? .object([
          "tool": .string("xml.read"),
          "path": .string(info.projectRelativePath),
        ])
        : .null,
    ])
  }
}

internal struct ProjectSourceFileDescriptor {
  var language: String
  var kind: String
  var matchSource: String = "extension"
}

internal struct ProjectSourceFileInfo {
  var info: FileInfo
  var language: String
  var kind: String
  var matchSource: String

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "project_relative_path": .string(info.projectRelativePath),
      "name": .string((info.projectRelativePath as NSString).lastPathComponent),
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

private struct ProjectCommandManifestReadResult {
  var content: String
  var fileTruncated: Bool
  var parseError: String?
}

internal struct ProjectCommandManifestParseResult {
  var commands: [ProjectCommandInfo]
  var errors: [ProjectCommandParseError]
  var fileTruncated: Bool
}

internal struct ProjectCommandParseError {
  var sourceProjectRelativePath: String
  var message: String

  var json: JSONValue {
    .object([
      "source_project_relative_path": .string(sourceProjectRelativePath),
      "message": .string(message),
    ])
  }
}

internal struct ProjectCommandInfo {
  var sourcePath: String
  var sourceProjectRelativePath: String
  var cwdProjectRelativePath: String
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
      "source_project_relative_path": .string(sourceProjectRelativePath),
      "cwd_project_relative_path": .string(cwdProjectRelativePath),
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
