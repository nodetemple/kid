# kid - [Kubernetes](http://kubernetes.io) in [Docker](https://www.docker.com)

Launch Kubernetes in Docker in one `kid up` command.

```
$ kid
kid is a utility for launching Kubernetes in Docker

Usage: kid [command]

Available commands:
  up       Starts Kubernetes in the Docker host currently configured with your local docker command
  down     Tear down a previously started Kubernetes cluster
  restart  Restart Kubernetes
```

On Linux kid will launch Kubernetes using the local Docker Engine.

On OS X Kubernetes will be started in the boot2docker VM via Docker Machine. kid sets up port forwarding so that you can use kubectl locally without having to ssh into boot2docker.

kid also sets up:

 * The [DNS addon](https://github.com/kubernetes/kubernetes/tree/master/cluster/addons/dns)
 * The [Kubernetes Dashboard](https://github.com/kubernetes/dashboard)

## Installation
```
curl -Ls https://git.io/ntkid | bash
```
