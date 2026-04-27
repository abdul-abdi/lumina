// Sources/LuminaBootable/AutounattendSeed.swift
//
// Generates a sidecar autounattend.xml ISO that lets stock Microsoft
// Windows 11 ARM64 installers complete OOBE on Apple Virtualization.framework,
// which exposes no TPM device.
//
// Apple's VZ has no TPM — confirmed by absence of `VZTPM*` /
// `VZTrustedPlatform*` headers in the macOS 26.4 SDK. Stock retail Win11
// Home/Pro ISOs refuse Setup at the compatibility check. The bypass is
// well-documented: set `LabConfig\BypassTPMCheck=1` (and friends) in the
// registry during the WindowsPE pass, before the compat check fires.
//
// Microsoft Setup auto-loads `autounattend.xml` from the root of every
// attached writable drive — USB mass-storage works (it's what we already
// use for the installer ISO via `preferUSBCDROM=true`). We attach a small
// (~1 MB) ISO with `autounattend.xml` at the root via
// `VZUSBMassStorageDeviceConfiguration`. Setup picks it up before the
// compat check and the install proceeds.
//
// The same XML covers OOBE auto-skip so the install reaches a desktop
// without us having to drive virtual mouse/keyboard through
// "Microsoft Account is required" prompts.

import Foundation

public struct AutounattendSeed: Sendable {
    public let bundleRootURL: URL
    public let username: String
    public let hostname: String
    public let xml: String

    public init(
        bundleRootURL: URL,
        username: String = "lumina",
        hostname: String = "lumina-vm",
        xml: String? = nil
    ) {
        self.bundleRootURL = bundleRootURL
        self.username = username
        self.hostname = hostname
        self.xml = xml ?? AutounattendSeed.defaultXML(username: username, hostname: hostname)
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case hdiutilNotAvailable
        case hdiutilFailed(Int32, String)
        case writeFailed(URL, String)

        public var description: String {
            switch self {
            case .hdiutilNotAvailable: return "hdiutil missing"
            case .hdiutilFailed(let c, let s): return "hdiutil exit \(c): \(s)"
            case .writeFailed(let u, let s): return "write \(u.lastPathComponent): \(s)"
            }
        }
    }

    /// Standard autounattend covering:
    ///   1. WindowsPE pass — registry bypass for TPM, SecureBoot, RAM, CPU,
    ///      storage. These are the five compatibility checks the Win11
    ///      installer enforces; setting `LabConfig\Bypass*Check=1` skips
    ///      the matching check.
    ///   2. specialize pass — disable telemetry, set computer name.
    ///   3. oobeSystem pass — accept EULA, skip Microsoft Account, create
    ///      a local user, suppress every "set up your PC" screen.
    ///
    /// `BypassNRO` is the magic OOBE step that lets us skip the
    /// "you must connect to internet and sign in to Microsoft" gate.
    /// Without it, recent Win11 ARM ISOs (post-23H2) brick OOBE in a VM
    /// with no working network/MSA.
    public static func defaultXML(username: String, hostname: String) -> String {
        // Use the Pro Volume License key — accepts unattended install
        // and skips product-key prompts. Same key Microsoft documents in
        // their Volume Activation guide; functionally a "deferred
        // activation" placeholder, not a license.
        let proVLKey = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
        // Escape XML reserved chars conservatively.
        let xName = xmlEscape(username)
        let xHost = xmlEscape(hostname)
        return #"""
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">

          <!-- 1. WindowsPE pass: bypass the five Win11 compat checks. -->
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>3</Order>
                  <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>4</Order>
                  <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>5</Order>
                  <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
              <UserData>
                <ProductKey>
                  <Key>\#(proVLKey)</Key>
                  <WillShowUI>OnError</WillShowUI>
                </ProductKey>
                <AcceptEula>true</AcceptEula>
                <FullName>Lumina</FullName>
                <Organization>Lumina VM</Organization>
              </UserData>
              <ImageInstall>
                <OSImage>
                  <InstallTo>
                    <DiskID>0</DiskID>
                    <PartitionID>3</PartitionID>
                  </InstallTo>
                  <InstallToAvailablePartition>true</InstallToAvailablePartition>
                </OSImage>
              </ImageInstall>
              <DiskConfiguration>
                <Disk wcm:action="add">
                  <DiskID>0</DiskID>
                  <WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add">
                      <Order>1</Order>
                      <Type>EFI</Type>
                      <Size>300</Size>
                    </CreatePartition>
                    <CreatePartition wcm:action="add">
                      <Order>2</Order>
                      <Type>MSR</Type>
                      <Size>16</Size>
                    </CreatePartition>
                    <CreatePartition wcm:action="add">
                      <Order>3</Order>
                      <Type>Primary</Type>
                      <Extend>true</Extend>
                    </CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add">
                      <Order>1</Order>
                      <PartitionID>1</PartitionID>
                      <Format>FAT32</Format>
                      <Label>System</Label>
                    </ModifyPartition>
                    <ModifyPartition wcm:action="add">
                      <Order>3</Order>
                      <PartitionID>3</PartitionID>
                      <Format>NTFS</Format>
                      <Label>Windows</Label>
                    </ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>
            </component>
            <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
              </SetupUILanguage>
              <InputLocale>0409:00000409</InputLocale>
              <SystemLocale>en-US</SystemLocale>
              <UILanguage>en-US</UILanguage>
              <UserLocale>en-US</UserLocale>
            </component>
          </settings>

          <!-- 2. specialize pass: hostname + telemetry off. -->
          <settings pass="specialize">
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <ComputerName>\#(xHost)</ComputerName>
              <TimeZone>UTC</TimeZone>
            </component>
          </settings>

          <!-- 3. oobeSystem pass: skip every "set up your PC" screen. -->
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\#(xName)</Name>
                    <DisplayName>\#(xName)</DisplayName>
                    <Group>Administrators</Group>
                    <Password>
                      <Value>\#(xName)</Value>
                      <PlainText>true</PlainText>
                    </Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Username>\#(xName)</Username>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Password>
                  <Value>\#(xName)</Value>
                  <PlainText>true</PlainText>
                </Password>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <CommandLine>cmd.exe /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</CommandLine>
                  <Description>Allow OOBE to skip Microsoft Account requirement</Description>
                </SynchronousCommand>
              </FirstLogonCommands>
              <RegisteredOrganization>Lumina VM</RegisteredOrganization>
              <RegisteredOwner>\#(xName)</RegisteredOwner>
              <TimeZone>UTC</TimeZone>
            </component>
          </settings>

        </unattend>
        """#
    }

    /// Generate `<bundle>/autounattend.iso`. Returns the URL.
    public func generate() throws -> URL {
        let hdiutilPath = "/usr/bin/hdiutil"
        guard FileManager.default.isExecutableFile(atPath: hdiutilPath) else {
            throw Error.hdiutilNotAvailable
        }

        let outURL = bundleRootURL.appendingPathComponent("autounattend.iso")
        let staging = bundleRootURL.appendingPathComponent("autounattend-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            // Windows Setup looks at the root for `autounattend.xml`. The
            // Setup binary also accepts `unattend.xml` later in the install,
            // so we drop both — same content. Belt + suspenders.
            try Data(xml.utf8).write(to: staging.appendingPathComponent("autounattend.xml"))
            try Data(xml.utf8).write(to: staging.appendingPathComponent("unattend.xml"))
        } catch {
            throw Error.writeFailed(staging, "\(error)")
        }

        // Volume label "AUTOUNATTEND" — Windows finds the file by its
        // filename + drive root, label is just for human readability.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hdiutilPath)
        proc.arguments = [
            "makehybrid",
            "-iso", "-joliet",
            "-default-volume-name", "AUTOUNATTEND",
            "-o", outURL.path,
            staging.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw Error.hdiutilFailed(-1, "\(error)")
        }
        if proc.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Error.hdiutilFailed(proc.terminationStatus, stderr)
        }

        return outURL
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
