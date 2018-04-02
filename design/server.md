# REQ-server_design_notes
partof: REQ-purpose
###

This contains design considerations that the server has to handle.

## Failure to startup

The client try to connect to a distssh-server to query for a *least loaded remote host*.
How should the client detect that the distssh-server is down?

A timeout period?
If the timeout happens then the client spawn a new server?

## Server Consolidation

It can be a scenario where there are multiple distssh-server instances.
This should never be necessary.

How can they be automatically consolidated?

## Find Server

How should a client do to find a distssh-server?
On a local host it could probably just scan e.g. `/tmp/distssh-$USER-$SESSION.unix`.
That many be good enough?

It must check that the user own the socket and that it is read/write to only the user.
Otherwise it should gracefully find another socket to use.
Maybe $SESSION+1?
That should give a sequensial number.
An adversary could slow it down but never make it utterly fail.

And if one on a local server wants to *do evil* to other users it is easy to find out who it is and *correct* it.
But maybe a builtin monitor/warnings system for this?
Probably only when running distssh, not distcmd.

## Security Considerations

The most vulnerable spot is the unix domain socket file.
It must be ensured that is is owned by the user and only read/write permission for the user.
The implementation should be inspected and tested for this *extra much*.

## Connection Policy

I haven't decided yet what to do.

Policy 1.
 * One connection is one answer. Then it is teared down.
 * A client can send multiple requests to the server but will only get one answer.
This would make it easy to implement.

The server *gracefully* handles multiple requests by just answering one time.

This *maps* pretty well to how the distssh-client is used. It requests a list of how the hosts are loaded so it can choose among them.
That is all it does.
Then it tears down the connection.

Policy 2.
 * A connection stays open until it is teared down by the client.
Then I stopped thinking about it because policy 1 just seem to map much better to the inteded use.

## Configuration

There should be a way of configuring the server.
For now probably a file with the servers.
This is better than setting it via an environment variable.

But the env variable must still be supported because it makes it easier for the user to *customize* it when it is needed.

How will this customization interact with a server that is already running?
Hash of the configuration data?
The hash is part of the unix socket?
    The bad, unintended consequence could be that multiple clients scan the same remote hosts.
    Maybe ignore this for now because it could be a corner case that isn't *that bad* that it need to be solved.
    Especially if the *scan* time is *low*.

## Scan Strategy

Probably need different windows that it *jump* between depending on how often it is used.
This is to avoid overloading a specific server with *one* users requests.

The intention is to keep a *reasonably* updated list of how the servers are loaded.

Maybe something like this.

* Each user request trigger a scan of **one** of the three *least loaded remote hosts*.
  This should lead to an automatic regulation loop where the command being used often lead to the list being updated faster.
  This should *gracefully* update the list of remote hosts without being to spammy.
  This should make sure that the list is *popped* by those that the user are currently putting load on.
  This should update the list of those that the user are using.
* A timer that in a round robin fashion scan all the hosts.
  This should ensure that the load of all hosts are guaranteed to be updated.
* A timer that scan the most loaded host.
  It is on the assumption that the most loaded will be the least used by all distssh clients and thus when the job on it *finish* it should be *available* fast for use.
* The timers should be adjusted on the fly depending on how much the server is used.

# REQ-daemon_startup_responsibility
REQ-purpose
###

The `distssh --daemon` is responsible for creating a secure unix domain socket to communicate over.
The `distssh` is responsible for finding a secure unix domain socket to communicate over.
The `distssh` is reponsible for checking that there is a daemon on the other side of the socket to communicate with.
The `distssh` is responsible for spinning up a daemon if none is found to be working.

## Rationale
The frontend to the user is `distssh`.
By dividing the responsibility as this it simplifies the daemon to just creating a socket.

# REQ-secure_daemon_unix_domain_socket
partof: REQ-security
###

The program shall ensure that the created socket is owned and only read/writable by the current user.

## Implementation
A simple way is to generate use a function to create a secure temporary directory.

# SPC-cleanup_stale_sockets
partof: REQ-secure_daemon_unix_domain_socket
###

The program shall check for stale directories and sockets to cleanup when the daemon is started.

## Rationale
This is to prevent possible junk being accumulated if e.g. the server is running for a long time.
