-module(fuc_ffi).

-export([notify_ready/0]).

notify_ready() ->
    os:cmd("systemd-notify --ready").
