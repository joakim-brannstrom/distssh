# distssh
[![Build Status](https://dev.azure.com/wikodes/wikodes/_apis/build/status/joakim-brannstrom.distssh?branchName=master)](https://dev.azure.com/wikodes/wikodes/_build/latest?definitionId=4&branchName=master)

**distssh** is a frontend to ssh that find the least loaded host in a cluster and execute commands on it.

It can alternatively be used to find and run an interactive shell on the least loaded host.

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

This is the simplest usage. It gives you a shell at the cluster.

```sh
distshell
# or
distssh shell
```

## Remote Command

This will execute the command on the cluster.

```sh
distssh cmd -- ls
```

## Export the Environemnt to Remote Host

This is useful for those development environments where it is *heavy* to reload
the shell with the correct modules.  By exporting and then importing the
environment on the remote host this can be bypassed/sped up.

Note that this basically requires them to be equivalent.

```sh
# store an export of the env
distssh env -e
# now the env is reused on the remote hosts
distcmd ls
```

It is also possible to clone the current environment without first exporting it to a file.

```sh
distssh distcmd --clone-env -- ls
```

The exported environment can also be used to run commands locally.

```sh
distssh localrun -- env
```

## Cluster Load

Distssh can display the current load of the cluster. The servers that are
listed are those that distssh is currently able to connect to and that respond
within the `--timeout` limit.

The load is normalised to what is considered "best practice" when comparing the
value from `loadavg` by dividing it by the number of cores that are available
on the server. A server is most probably overloaded if it is above 1.0.

```sh
distssh measurehosts
```

## Purge

Even though `distssh` try to do a good job of cleaning up stale processes and
such when it logout of a server there are circumstances wherein a process can
be left dangling on a server in the cluster and take up resources. What
resource is obviously dependent on what type of process that is left.

`distssh` can `purge` these processes from the cluster. This can be executed
either manually or by the daemon in the background.

```sh
# print all processes that have escaped sshd, from all users
distssh purge -p
# print those that have escaped the current user
distssh purge -p --user-filter
# kill them
distssh purge -p --user-filter -k
```

# Configuration

These environment variables control the behavior of distssh.

 * `DISTSSH_HOSTS`: the hosts to load balance among. Hosts are separated by `;`.
Example:
```sh
export DISTSSH_HOSTS='localhost;some_remove'
distcmd ls
```

 * `DISTSSH_IMPORT_ENV`: filename to load the environment from.
Example:
```sh
export DISTSSH_IMPORT_ENV="$HOME/foo.export"
distcmd ls
```

 * `DISTSSH_ENV_EXPORT_FILTER`: environment keys to remove when creating an export. Keys are separated by `;`.
Example:
```sh
export DISTSSH_ENV_EXPORT_FILTER='PWD;USER;USERNAME;_'
distssh --export-env
```

 * `DISTSSH_AUTO_PURGE`: set the variable to `1` to activate automatic purge of
   processes that isn't part of a process subtree which contains a whitelisted
   process when the daemon is running.
Example:
```sh
export DISTSSH_AUTO_PURGE=1
```

 * `DISTSSH_PURGE_WLIST`: a list of case insensitive regex separated by `;`.
   Used both by the manual `purge` sub-command and the daemon mode.
Example:
```sh
# will purge all processes that have "escaped" an interactive sshd instance
export DISTSSH_PURGE_WLIST='.*sshd'
```
