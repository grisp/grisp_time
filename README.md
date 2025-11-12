grisp_time
=====

An OTP application for time synchronization using NTP.

Build
-----

    $ rebar3 compile

Configuration
-------------

The `grisp_time` application can be configured via environment variables in your `sys.config` file:

### `servers`

List of NTP server hostnames to use for time synchronization.
If an empty list is provided, the ntp deamon will not be started.

**Type:** `[string()]`

**Default:** `["0.pool.ntp.org", "1.pool.ntp.org", "2.pool.ntp.org", "3.pool.ntp.org"]`

**Example:**
```erlang
{grisp_time, [
    {servers, ["ntp.example.com", "time.example.com"]}
]}
```

### `ntpd`

Path to the ntpd executable.

**Type:** `string()`

**Default:** `"/usr/sbin/ntpd"`

**Example:**
```erlang
{grisp_time, [
    {ntpd, "/usr/local/bin/ntpd"}
]}
```

### Complete Configuration Example

```erlang
{grisp_time, [
    {servers, ["0.pool.ntp.org", "1.pool.ntp.org"]},
    {ntpd, "/usr/sbin/ntpd"}
]}
```
