# distssh

**distssh** is a frontend to ssh that check which server is the least loaded and login on that one.
It gives the user a shell to work in.

# Getting Started

distssh depends on the following software packages:

 * [D compiler](https://dlang.org/download.html) (dmd 2.072+, ldc 1.1.0+)

For users running Ubuntu one of the dependencies can be installed with apt.
```sh
sudo apt install x
```

Download the D compiler of your choice, extract it and add to your PATH shell
variable.
```sh
# example with an extracted DMD
export PATH=/path/to/dmd/linux/bin64/:$PATH
```

Once the dependencies are installed it is time to download the source code to install distssh.
```sh
git clone https://github.com/joakim-brannstrom/distssh.git
cd distssh
dub build -b release
```

Done! Have fun.
Don't be shy to report any issue that you find.
