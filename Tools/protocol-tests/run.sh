#!/bin/zsh
# Builds FileCat's protocol code for macOS and runs it against the servers from servers.sh.
# Usage: run.sh [all|webdav|nextcloud|nfs|smb|sftp|openssh|ftp|dialect|stream]
set -e
HERE=${0:A:h}
N=$HERE/../../FileCat/FileCat/Network
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=$(mktemp -d)/protocol-tests
if [[ $1 == stream ]]; then
  xcrun swiftc -O -target arm64-apple-macos15 -o $OUT $HERE/stream/main.swift \
    $N/NetworkSource.swift $N/RemoteFileSystem.swift $N/Wire.swift $N/SMBCrypto.swift $N/SMB2Client.swift \
    $N/SMBFileSystem.swift $N/NFSFileSystem.swift $N/WebDAVFileSystem.swift $N/ServiceDiscovery.swift \
    $N/SSHCrypto.swift $N/SSHClient.swift $N/SFTPFileSystem.swift $N/FTPFileSystem.swift \
    $N/RemoteStream.swift $N/../Audio/StreamingAudioDecoder.swift
  exec $OUT
fi
xcrun swiftc -O -target arm64-apple-macos15 -o $OUT $HERE/main.swift \
  $N/NetworkSource.swift $N/RemoteFileSystem.swift $N/Wire.swift $N/SMBCrypto.swift $N/SMB2Client.swift \
  $N/SMBFileSystem.swift $N/NFSFileSystem.swift $N/WebDAVFileSystem.swift $N/ServiceDiscovery.swift $N/NextcloudLogin.swift \
  $N/SSHCrypto.swift $N/SSHClient.swift $N/SFTPFileSystem.swift $N/FTPFileSystem.swift
$OUT ${1:-all}
