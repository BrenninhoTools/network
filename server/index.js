#!/usr/bin/env node
'use strict';

const { createServer } = require('./src/server');

function parseArgs(argv) {
	const options = {};
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (!arg.startsWith('--')) continue;
		const [key, inline] = arg.slice(2).split('=');
		const value = inline !== undefined ? inline : (argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : 'true');
		options[key] = value;
	}
	return options;
}

const args = parseArgs(process.argv.slice(2));
const env = process.env;

const options = {
	port: Number(args.port || env.PORT || 7777),
	host: args.host || env.HOST || '0.0.0.0',
	path: args.path || env.NETWORK_PATH || '/',
	motd: args.motd || env.NETWORK_MOTD || '',
	dataFile: args.data || env.NETWORK_DATA || null,
	maxClients: Number(args['max-clients'] || env.NETWORK_MAX_CLIENTS || 1000),
	maxRooms: Number(args['max-rooms'] || env.NETWORK_MAX_ROOMS || 500),
	maxPlayersPerRoom: Number(args['max-players'] || env.NETWORK_MAX_PLAYERS || 16),
	allowedOrigins: (args.origins || env.NETWORK_ORIGINS || '').split(',').map((origin) => origin.trim()).filter((origin) => origin.length > 0),
	log: args.quiet !== 'true'
};

const server = createServer(options);
server.listen();

function shutdown() {
	server.close().then(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
