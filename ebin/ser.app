{
    application, ser,
	    [
		{description, "Application for tearing down calls"},
		{vsn, "0.1"},
		{modules, [ser, ser_app, ser_sup]},
		{registered, [ser, ser_sup]},
		{applications, [kernel, stdlib, erlsyslog]},
		{env,
			[
				{listen_address, {{127,0,0,1}, 22222}},
				{rtpproxy_node, 'rtpproxy@example.com'},
				{syslog_address, {"localhost", 514}}
			]},
		{mod, {ser_app, []}}
	    ]
}.