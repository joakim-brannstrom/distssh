# Choose Best Remote Host

This explores different approaches for how to choose the best remote host.

Any approach other than LoadAvg must be verified that it is better than that.

## LoadAvg

1. Measure the loadavg and the time it took to make connect+measure+answer of all remote hosts.
2. Sort by the loadavg followed by access time.
3. Choose at random one of the top 3

Go through and update the measurement of the hosts in a round roubin fashion at the interval of 1 per 30s.

Because the top three will probably change the most they need to be updated more.
Measure at random one of the top 3 each 10s.

The total number of measurements per hour is: 480

## Extended Kalman Filter

A extended kalman filter is used to predicate what the load will be in the future.

1. Use the predication of 1min into the future of what the load will be.
2. Sort by the load
3. Choose at random one of the top 3. (Or not? Can it be assumed that different clients predicate differently?)

Go through and measure one host each 30s.
The one to measure is the remote host with the worst covarians.

## FIR Filter

Simple filter:
```
Y=x0+h1*x1+h2*x2+....
```

H is a constant
x1, x2 etc are delayed.
Old values
