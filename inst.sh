#!/bin/bash

echo 'Script used to install utility programs in RHEL based machines'
name=(`grep -P '^(VERSION_ID|ID)=' /etc/os-release | awk -F'"' '{ print $2 }' | xargs`)

if [[ ${name[0]} =~ centos|rhel && ${name[1]} =~ 7|8 ]]; then
    echo 'Proceeding with installation of utility programs'
else
    echo 'Script currently supports CentOS/RHEL 7/8 machines'
fi

PS3='Please select one of the options to install corresponding programs: '

ius_inst() {
    sudo yum -y install epel-release
    sudo yum -y install https://centos7.iuscommunity.org/ius-release.rpm
}

tmux_inst() {
    ius
    sudo yum install -y tmux2u
}

git_inst(){
    ius
    sudo yum install -y git2u-all
}

py36_inst(){
    ius
    sudo yum -y install python36u python36u-pip python36u-devel
}

select option in neovim neovim_appimage tmux_v2 git_v2 ripgrep fzf python_v36 quit
do
    case $option in
        neovim)
            sudo curl -o /etc/yum.repos.d/dperson-neovim-epel-7.repo https://copr.fedorainfracloud.org/coprs/dperson/neovim/repo/epel-7/dperson-neovim-epel-7.repo
            sudo yum -y install neovim --enablerepo=epel
            ;;
        neovim_appimage)
            echo 'Neovim appimage will be downloaded to $HOME/.nvim'
            mkdir -p $HOME/.nvim && cd "$_"
            curl -LO https://github.com/neovim/neovim/releases/download/stable/nvim.appimage
            cd $HOME/.nvim
            chmod u+x nvim.appimage && ./nvim.appimage --appimage-extract 1>/dev/null
            cd -
            echo 'alias nvim=$HOME/.nvim/squashfs-root/usr/bin/nvim' >> ~/.bashrc
            ;;
        tmux_v2)
            tmux_inst
            ;;
        git_v2)
            git_inst
            ;;
        ripgrep)
            sudo yum -y install epel-release
            sudo yum-config-manager --add-repo=https://copr.fedorainfracloud.org/coprs/carlwgeorge/ripgrep/repo/epel-7/carlwgeorge-ripgrep-epel-7.repo
            sudo yum install ripgrep
            ;;
        fzf)
            git
            mkdir -p $HOME/.fzf && cd "$_"
            git clone --depth 1 https://github.com/junegunn/fzf.git
            ./install
            cd -
            ;;
        python_v36)
            py36_inst
            ;;
        pyls)
            py36_inst
            pip3 install jedi
            pip3 install 'python-language-server'
            pip3 install 'python-language-server[yapf]'
            ;;
        quit)
            echo 'END'
            break
            ;;
        *)
            echo 'Please select correct option'
            ;;
    esac
done

