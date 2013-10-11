#!/bin/sh
CODE_DIR=ubuntu-keyboard
USER=phablet
USER_ID=32011
PASSWORD=phablet
PACKAGE=ubuntu-keyboard
BINARY=maliit-server
TARGET_IP=127.0.0.1
TARGET_SSH_PORT=2222
TARGET_DEBUG_PORT=3768
RUN_OPTIONS=""
# -qmljsdebugger=port:$TARGET_DEBUG_PORT"
SETUP=false
SUDO="echo $PASSWORD | sudo -S"

usage() {
    echo "usage: run_on_device [OPTIONS]\n"
    echo "Script to setup a build environment for the shell and sync build and run it on the device\n"
    echo "OPTIONS:"
    echo "  -s, --setup   Setup the build environment"
    echo ""
    echo "IMPORTANT:"
    echo " * Make sure to have the networking and PPAs setup on the device beforehand (phablet-deploy-networking && phablet-ppa-fetch)."
    echo " * Execute that script from a directory containing a branch of the shell code."
    exit 1
}

exec_with_ssh() {
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t $USER@$TARGET_IP -p $TARGET_SSH_PORT "bash -ic \"$@\""
}

exec_with_adb() {
    adb shell chroot /data/ubuntu /usr/bin/env -i PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin "$@"
}

adb_root() {
    adb root
    adb wait-for-device
}

install_ssh_key() {
    ssh-keygen -R $TARGET_IP
    HOME_DIR=/home/phablet
    adb push ~/.ssh/id_rsa.pub $HOME_DIR/.ssh/authorized_keys
    adb shell chown $USER_ID:$USER_ID $HOME_DIR/.ssh
    adb shell chown $USER_ID:$USER_ID $HOME_DIR/.ssh/authorized_keys
    adb shell chmod 700 $HOME_DIR/.ssh
    adb shell chmod 600 $HOME_DIR/.ssh/authorized_keys
    adb shell rm /etc/init/ssh.override
}

install_dependencies() {
    exec_with_adb apt-get -y install openssh-server
    adb shell start ssh
    sleep 2
    exec_with_ssh $SUDO apt-get -y install build-essential rsync bzr ccache gdb libglib2.0-bin
    exec_with_ssh $SUDO apt-get -y install emacs23-nox mc unzip
    exec_with_ssh $SUDO add-apt-repository -y ppa:canonical-qt5-edgers/qt5-proper
    exec_with_ssh $SUDO add-apt-repository -s -y ppa:phablet-team/ppa
    exec_with_ssh $SUDO apt-get update
    exec_with_ssh $SUDO apt-get -y install qt5-qmake qtdeclarative5-dev-tools qtdeclarative5-test-plugin qtdeclarative5-private-dev libqt5v8-5-private-dev fakeroot
    exec_with_ssh $SUDO apt-get -y install maliit-framework-dev libpinyin2-dev pkg-config libubuntu-platform-api1-dev debhelper qt5-default libgl-dev doxygen libhunspell-dev libpresage-dev libglib2.0-dev
    exec_with_ssh $SUDO apt-get -y build-dep $PACKAGE
}

reset_screen_powerdown() {
    exec_with_ssh $SUDO dbus-launch gsettings set com.canonical.powerd activity-timeout 600
    exec_with_ssh $SUDO sudo initctl restart powerd
}

setup_adb_forwarding() {
    adb forward tcp:$TARGET_SSH_PORT tcp:22
    adb forward tcp:$TARGET_DEBUG_PORT tcp:$TARGET_DEBUG_PORT
}

sync_code() {
    bzr export --uncommitted --format=dir /tmp/$CODE_DIR
    rsync -crlOzv -e "ssh -p $TARGET_SSH_PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no" /tmp/$CODE_DIR/ $USER@$TARGET_IP:$CODE_DIR/
    rm -rf /tmp/$CODE_DIR
}

build() {
    # same options as in debian/rules
    QMAKE_OPTIONS="-recursive MALIIT_DEFAULT_PROFILE=ubuntu CONFIG+=\\\"debug nodoc notests enable-presage enable-hunspell enable-preedit enable-pinyin enable-qt-mobility\\\""
    exec_with_ssh "cd $CODE_DIR/ && qmake $QMAKE_OPTIONS && make -j 4"
    echo "Installing"
    adb shell pkill "maliit-server"
    exec_with_ssh "cd $CODE_DIR/ && " $SUDO " make install"
#    exec_with_ssh "cd $CODE_DIR/ && dpkg-buildpackage -j4"
}

run() {
    exec_with_ssh $SUDO "/sbin/initctl stop maliit-server"
    adb shell pkill $BINARY
    adb shell pkill "webbrowser-app"
    adb shell pkill "qmlscene"

#    exec_with_ssh "$BINARY $RUN_OPTIONS"
}

set -- `getopt -n$0 -u -a --longoptions="setup,help" "sh" "$@"`

# FIXME: giving incorrect arguments does not call usage and exit
while [ $# -gt 0 ]
do
    case "$1" in
       -s|--setup)   SETUP=true;;
       -h|--help)    usage;;
       --)           shift;break;;
    esac
    shift
done

adb_root
setup_adb_forwarding

if $SETUP; then
    echo "Setting up environment for building shell.."
    install_ssh_key
    install_dependencies
    reset_screen_powerdown
    sync_code
else
    echo "Transferring code.."
    sync_code
    echo "Building.."
    build
    echo "Running.."
    run
fi
