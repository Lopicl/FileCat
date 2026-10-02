#!/bin/zsh
# Starts local servers for FileCat's network tests, all sharing $FILECAT_TEST_ROOT
# (default /tmp/filecat-test-server) and listening on 127.0.0.1 only:
#
#   WebDAV     127.0.0.1:8081   user "test", password "secret"          (rclone)
#   Nextcloud  127.0.0.1:8082   Login Flow v2 mock + WebDAV              (nextcloud_mock.py + rclone on 8084)
#   NFS v3     127.0.0.1:12049  export "/"                               (rclone)
#   SMB 3.1.1  127.0.0.1:4451   share "Media", your Mac user name, password "secret", signing required (Samba)
#   SFTP       127.0.0.1:2222   user "test", password "secret"          (rclone)
#   SFTP       127.0.0.1:2223-2225  OpenSSH sshd as you, key sign-in only (keys in $STATE/sshd/authorized_keys),
#                               each with different algorithms; 2223 renews its keys every 1 MB
#   FTP        127.0.0.1:2121   user "test", password "secret"          (rclone)
#   FTPS       127.0.0.1:2990   implicit TLS ("ftps://" address), self-signed certificate   (rclone)
#   FTPS       127.0.0.1:2991   explicit TLS (AUTH TLS), the same certificate (ftp_server.py)
#   FTPS       127.0.0.1:2992   explicit TLS that requires TLS session reuse (ftp_server.py)
#   FTP        127.0.0.1:2122   without MLSD, so listings use LIST       (ftp_server.py)
#
# Needs: brew install rclone samba
# Stop everything with: servers.sh stop
set -e
HERE=${0:A:h}
ROOT=${FILECAT_TEST_ROOT:-/tmp/filecat-test-server}
STATE=/tmp/filecat-test-state

pkill -f "[r]clone serve (webdav|nfs|sftp|ftp) $ROOT" || true
for pid in $STATE/sshd/*.pid(N); do kill $(cat $pid) 2>/dev/null || true; done
pkill -f "[n]extcloud_mock.py" || true
pkill -f "[f]tp_server.py" || true
pkill -f "[s]amba-dot-org-smbd --foreground" || true
[[ $1 == stop ]] && exit 0

# Test files: the same set the UI tests expect.
mkdir -p $ROOT/{Music,Photos,Empty}
echo "hello over the network" > $ROOT/hello.txt
[[ -f $ROOT/big.bin ]] || dd if=/dev/urandom of=$ROOT/big.bin bs=1m count=5 2>/dev/null
SAMPLES=${FILECAT_SAMPLES:-/tmp/folio-samples}
[[ -d $SAMPLES/Music ]] && cp -n $SAMPLES/Music/* $ROOT/Music/ 2>/dev/null || true
[[ -d $SAMPLES/Photos ]] && cp -n $SAMPLES/Photos/* $ROOT/Photos/ 2>/dev/null || true
# Spoken audio in a few formats, for the streaming tests.
if [[ ! -f $ROOT/Music/stream.flac ]]; then
  say -o $STATE-speech.aiff "This is a streaming test for FileCat. One two three four five six seven eight nine ten." 2>/dev/null && {
    afconvert -f m4af -d aac $STATE-speech.aiff $ROOT/Music/stream.m4a
    afconvert -f flac -d flac $STATE-speech.aiff $ROOT/Music/stream.flac
    afconvert -f WAVE -d LEI16 $STATE-speech.aiff $ROOT/Music/stream.wav
    rm -f $STATE-speech.aiff
  } || true
fi

mkdir -p $STATE
nohup rclone serve webdav $ROOT --addr 127.0.0.1:8081 --user test --pass secret > $STATE/webdav.log 2>&1 &
nohup rclone serve webdav $ROOT --addr 127.0.0.1:8084 --baseurl /remote.php/dav/files/test --user test --pass secret > $STATE/webdav-nextcloud.log 2>&1 &
nohup python3 $HERE/nextcloud_mock.py > $STATE/nextcloud.log 2>&1 &
nohup rclone serve nfs $ROOT --addr 127.0.0.1:12049 --vfs-cache-mode full > $STATE/nfs.log 2>&1 &
nohup rclone serve sftp $ROOT --addr 127.0.0.1:2222 --user test --pass secret > $STATE/sftp.log 2>&1 &
nohup rclone serve ftp $ROOT --addr 127.0.0.1:2121 --user test --pass secret --passive-port 30000-30100 > $STATE/ftp.log 2>&1 &
[[ -f $STATE/ftps.pem ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=FileCat Test" \
  -keyout $STATE/ftps.key -out $STATE/ftps.pem 2>/dev/null
nohup rclone serve ftp $ROOT --addr 127.0.0.1:2990 --user test --pass secret --passive-port 30101-30200 \
  --cert $STATE/ftps.pem --key $STATE/ftps.key > $STATE/ftps.log 2>&1 &
# In its own session, so it outlives the shell that started it (like smbd below).
nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' python3 $HERE/ftp_server.py $ROOT $STATE/ftps.pem $STATE/ftps.key > $STATE/ftp-python.log 2>&1 &

# OpenSSH, running as you: key sign-in only (the protocol tests write their key to authorized_keys).
SSHD=$STATE/sshd
mkdir -p $SSHD
[[ -f $SSHD/host_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -f $SSHD/host_ed25519
[[ -f $SSHD/host_ecdsa ]] || ssh-keygen -q -t ecdsa -b 256 -N "" -f $SSHD/host_ecdsa
[[ -f $SSHD/host_rsa ]] || ssh-keygen -q -t rsa -b 3072 -N "" -f $SSHD/host_rsa
touch $SSHD/authorized_keys
start_sshd() { # port, extra options
  local port=$1; shift
  cat > $SSHD/$port.conf <<CONF
Port $port
ListenAddress 127.0.0.1
PidFile $SSHD/$port.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $SSHD/authorized_keys
Subsystem sftp /usr/libexec/sftp-server
CONF
  for option in "$@"; do echo $option >> $SSHD/$port.conf; done
  /usr/sbin/sshd -f $SSHD/$port.conf -E $SSHD/$port.log
}
start_sshd 2223 "HostKey $SSHD/host_ed25519" "RekeyLimit 1M"
start_sshd 2224 "HostKey $SSHD/host_ecdsa" "KexAlgorithms ecdh-sha2-nistp256" "Ciphers aes128-ctr" "MACs hmac-sha2-256"
start_sshd 2225 "HostKey $SSHD/host_rsa" "KexAlgorithms ecdh-sha2-nistp521" "Ciphers aes256-ctr" "MACs hmac-sha2-512-etm@openssh.com" "HostKeyAlgorithms rsa-sha2-256"

# Samba, running as you, on a high port.
SMBD=$(brew --prefix)/sbin/samba-dot-org-smbd
if [[ -x $SMBD ]]; then
  mkdir -p $STATE/samba/{lock,state,cache,pid,priv,log}
  cat > $STATE/samba/smb.conf <<CONF
[global]
   smb ports = 4451
   interfaces = 127.0.0.1
   bind interfaces only = yes
   lock directory = $STATE/samba/lock
   state directory = $STATE/samba/state
   cache directory = $STATE/samba/cache
   pid directory = $STATE/samba/pid
   private dir = $STATE/samba/priv
   ncalrpc dir = $STATE/samba/state/ncalrpc
   log file = $STATE/samba/log/log.%m
   passdb backend = tdbsam:$STATE/samba/priv/passdb.tdb
   server role = standalone server
   server min protocol = SMB2_02
   server signing = mandatory
   disable netbios = yes
   map to guest = never
   load printers = no
   printing = bsd
   printcap name = /dev/null
[Media]
   path = $ROOT
   read only = no
   valid users = $USER
   nt acl support = no
   store dos attributes = no
   create mask = 0644
   force create mode = 0644
   directory mask = 0755
   force directory mode = 0755
   vfs objects =
CONF
  (echo secret; echo secret) | pdbedit --configfile=$STATE/samba/smb.conf -a -u $USER -t >/dev/null 2>&1 || true
  # smbd signals its whole process group when it stops, so give it its own session.
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' $SMBD --foreground --no-process-group --configfile=$STATE/samba/smb.conf --debug-stdout > $STATE/samba/smbd.out 2>&1 &
else
  echo "Samba not installed (brew install samba); skipping SMB."
fi
sleep 4
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ":(8081|8082|8084|12049|4451|2222|2223|2224|2225|2121|2990|2991|2992|2122) " | awk '{print "listening:", $9}'
