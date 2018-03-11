# distssh

**distssh** is a frontend to ssh that check which server is the least loaded and login on that one.
It gives the user a shell to work in.

# Getting Started

distssh depends on the following software packages:

 * [D compiler](https://dlang.org/download.html)

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

Copy the file in build/ to wherever you want to install it.
When you have placed it at where you want the run the install command to setup the needed symlinks:
```sh
/my/install/path/distssh --install
```

Done! Have fun.
Don't be shy to report any issue that you find.

# Usage

For distssh to be useful the environment variable DISTSSH_HOSTS has to be set.
The `;` is used to separate hosts.
Example:
```sh
export DISTSSH_HOSTS='foo;bar;wun'
```

When that is done it is now ready to use!

## Remote Shell

This is the simplest usage.
```sh
distshell
# or
distssh --shell
```

## Remote Command

```sh
distcmd ls
# or
distssh -- ls
```

## Export the Environemnt to Remote Host

This is useful for those development environments where it is *heavy* to reload the shell with the correct modules.
By exporting and then importing the environment on the remote host this can be bypassed/sped up.

Note that this basically requires them to be equivalent.

```sh
# store an export of the env
distssh --export-env
# or export and run command
distssh --export-env ls
# now the env is reused on the remote hosts
distcmd ls
```
