import Foundation

// Entry point. Hand-rolled subcommand dispatch (no external arg-parser dependency
// — see Package.swift for the rationale).
//
//   smbmounter daemon [--config <path>]   main loop; launchd invokes this
//   smbmounter status                     list all mounts and their state
//   smbmounter mount <name>               force-mount a configured share
//   smbmounter unmount [-f] <name>        unmount (clean; -f forces)
//   smbmounter reload                     reload config in the running daemon
//   smbmounter setup <name>               store the SMB credential (interactive)
//   smbmounter setup --check              print the autofs migration checklist
//   smbmounter probe <name>               run a one-shot health probe
//   smbmounter version

// Ignore SIGPIPE process-wide so a dropped socket peer can never kill us.
signal(SIGPIPE, SIG_IGN)

func usage() {
    let text = """
    smbmounter \(Constants.version) — SMB auto-mounter daemon for macOS

    USAGE:
      smbmounter <subcommand> [options]

    SUBCOMMANDS:
      daemon [--config <path>]   Run the daemon (launchd invokes this).
      status                     Show state of every configured mount.
      mount <name>               Force-mount a configured share.
      unmount [-f] <name>        Unmount a share (-f to force).
      reload                     Reload config in the running daemon.
      setup <name>               Store the SMB credential in the System keychain.
      setup --check              Print the autofs migration checklist.
      probe <name>               Run a one-shot health probe and print the result.
      version                    Print the version.
    """
    print(text)
}

/// Pull `--config <path>` out of an argument list, returning the path (if any)
/// and the remaining args.
func extractConfigPath(_ args: [String]) -> (path: String, rest: [String]) {
    var path = Constants.defaultConfigPath
    var rest: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == "--config", i + 1 < args.count {
            path = args[i + 1]
            i += 2
        } else {
            rest.append(args[i])
            i += 1
        }
    }
    return (path, rest)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let subcommand = arguments.first

switch subcommand {
case "daemon":
    let (configPath, _) = extractConfigPath(Array(arguments.dropFirst()))
    Daemon(configPath: configPath).run()   // never returns

case "__mount-helper":
    // Internal: the root daemon re-execs this to mount as a dropped-privilege user.
    runMountHelper(Array(arguments.dropFirst()))   // never returns

case "status":
    exit(CLI.status())

case "mount":
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("usage: smbmounter mount <name>\n".utf8))
        exit(2)
    }
    exit(CLI.mount(name: arguments[1]))

case "unmount", "umount":
    // accept `unmount -f <name>` or `unmount <name>`
    let rest = Array(arguments.dropFirst())
    let force = rest.contains("-f") || rest.contains("--force")
    guard let name = rest.first(where: { !$0.hasPrefix("-") }) else {
        FileHandle.standardError.write(Data("usage: smbmounter unmount [-f] <name>\n".utf8))
        exit(2)
    }
    exit(CLI.unmount(name: name, force: force))

case "reload":
    exit(CLI.reload())

case "probe":
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("usage: smbmounter probe <name>\n".utf8))
        exit(2)
    }
    exit(CLI.probe(name: arguments[1]))

case "setup":
    exit(CLI.setup(args: Array(arguments.dropFirst())))

case "version", "--version", "-v":
    print("smbmounter \(Constants.version)")

case nil, "help", "-h", "--help":
    usage()

default:
    FileHandle.standardError.write(Data("smbmounter: unknown subcommand '\(subcommand ?? "")'\n".utf8))
    usage()
    exit(2)
}
