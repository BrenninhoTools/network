'use strict';

const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const OPCODES = {
	CONTINUATION: 0x0,
	TEXT: 0x1,
	BINARY: 0x2,
	CLOSE: 0x8,
	PING: 0x9,
	PONG: 0xa
};

function acceptKey(key) {
	return crypto.createHash('sha1').update(key + GUID).digest('base64');
}

function encodeFrame(opcode, payload) {
	const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || '');
	const length = data.length;
	let header;

	if (length < 126) {
		header = Buffer.alloc(2);
		header[1] = length;
	} else if (length < 65536) {
		header = Buffer.alloc(4);
		header[1] = 126;
		header.writeUInt16BE(length, 2);
	} else {
		header = Buffer.alloc(10);
		header[1] = 127;
		header.writeBigUInt64BE(BigInt(length), 2);
	}

	header[0] = 0x80 | opcode;
	return Buffer.concat([header, data]);
}

class WebSocketConnection extends EventEmitter {
	constructor(socket, request, options) {
		super();
		this.socket = socket;
		this.request = request;
		this.maxPayload = options.maxPayload;
		this.buffer = Buffer.alloc(0);
		this.fragments = [];
		this.fragmentOpcode = 0;
		this.fragmentLength = 0;
		this.open = true;
		this.closeSent = false;
		this.lastPong = Date.now();
		this.remoteAddress = (request.headers['x-forwarded-for'] || socket.remoteAddress || '').split(',')[0].trim();

		socket.setNoDelay(true);
		socket.on('data', (chunk) => this.onData(chunk));
		socket.on('close', () => this.finish(1006, 'Connection lost'));
		socket.on('error', () => this.finish(1006, 'Socket error'));
	}

	onData(chunk) {
		this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);

		while (this.open) {
			const frame = this.readFrame();
			if (frame === null) break;
			if (frame === false) return;
			this.handleFrame(frame);
		}
	}

	readFrame() {
		const buffer = this.buffer;
		if (buffer.length < 2) return null;

		const fin = (buffer[0] & 0x80) !== 0;
		const rsv = buffer[0] & 0x70;
		const opcode = buffer[0] & 0x0f;
		const masked = (buffer[1] & 0x80) !== 0;
		let length = buffer[1] & 0x7f;
		let offset = 2;

		if (rsv !== 0) {
			this.fail(1002, 'Reserved bits are not supported');
			return false;
		}

		if (!masked) {
			this.fail(1002, 'Client frames must be masked');
			return false;
		}

		if (length === 126) {
			if (buffer.length < 4) return null;
			length = buffer.readUInt16BE(2);
			offset = 4;
		} else if (length === 127) {
			if (buffer.length < 10) return null;
			const big = buffer.readBigUInt64BE(2);
			if (big > BigInt(this.maxPayload)) {
				this.fail(1009, 'Message too big');
				return false;
			}
			length = Number(big);
			offset = 10;
		}

		if (length > this.maxPayload) {
			this.fail(1009, 'Message too big');
			return false;
		}

		if (buffer.length < offset + 4 + length) return null;

		const mask = buffer.subarray(offset, offset + 4);
		offset += 4;
		const payload = Buffer.allocUnsafe(length);

		for (let i = 0; i < length; i++) {
			payload[i] = buffer[offset + i] ^ mask[i & 3];
		}

		this.buffer = buffer.subarray(offset + length);
		return { fin, opcode, payload };
	}

	handleFrame(frame) {
		switch (frame.opcode) {
			case OPCODES.TEXT:
			case OPCODES.BINARY:
				if (this.fragmentOpcode !== 0) {
					this.fail(1002, 'Expected a continuation frame');
					return;
				}
				if (frame.fin) {
					this.deliver(frame.opcode, frame.payload);
				} else {
					this.fragmentOpcode = frame.opcode;
					this.fragments = [frame.payload];
					this.fragmentLength = frame.payload.length;
				}
				break;
			case OPCODES.CONTINUATION:
				if (this.fragmentOpcode === 0) {
					this.fail(1002, 'Unexpected continuation frame');
					return;
				}
				this.fragments.push(frame.payload);
				this.fragmentLength += frame.payload.length;
				if (this.fragmentLength > this.maxPayload) {
					this.fail(1009, 'Message too big');
					return;
				}
				if (frame.fin) {
					const opcode = this.fragmentOpcode;
					const payload = Buffer.concat(this.fragments, this.fragmentLength);
					this.fragmentOpcode = 0;
					this.fragments = [];
					this.fragmentLength = 0;
					this.deliver(opcode, payload);
				}
				break;
			case OPCODES.PING:
				this.write(OPCODES.PONG, frame.payload);
				break;
			case OPCODES.PONG:
				this.lastPong = Date.now();
				break;
			case OPCODES.CLOSE: {
				const code = frame.payload.length >= 2 ? frame.payload.readUInt16BE(0) : 1005;
				const reason = frame.payload.length > 2 ? frame.payload.subarray(2).toString('utf8') : '';
				if (!this.closeSent) {
					this.closeSent = true;
					this.write(OPCODES.CLOSE, frame.payload.subarray(0, 2));
				}
				this.socket.end();
				this.finish(code, reason);
				break;
			}
			default:
				this.fail(1002, 'Unknown opcode');
		}
	}

	deliver(opcode, payload) {
		this.lastPong = Date.now();
		if (opcode === OPCODES.TEXT) this.emit('message', payload.toString('utf8'), false);
		else this.emit('message', payload, true);
	}

	write(opcode, payload) {
		if (!this.open || this.socket.destroyed) return false;
		this.socket.write(encodeFrame(opcode, payload));
		return true;
	}

	send(data) {
		if (Buffer.isBuffer(data) || data instanceof Uint8Array) return this.write(OPCODES.BINARY, Buffer.from(data));
		return this.write(OPCODES.TEXT, String(data));
	}

	ping() {
		return this.write(OPCODES.PING, Buffer.alloc(0));
	}

	close(code = 1000, reason = '') {
		if (!this.open) return;
		if (!this.closeSent) {
			this.closeSent = true;
			const text = Buffer.from(String(reason).slice(0, 120));
			const payload = Buffer.alloc(2 + text.length);
			payload.writeUInt16BE(code, 0);
			text.copy(payload, 2);
			this.write(OPCODES.CLOSE, payload);
		}
		setTimeout(() => this.socket.destroy(), 1000).unref();
		this.socket.end();
		this.finish(code, reason);
	}

	fail(code, reason) {
		this.close(code, reason);
	}

	finish(code, reason) {
		if (!this.open) return;
		this.open = false;
		this.emit('close', code, reason);
	}
}

function handleUpgrade(request, socket, head, options, onConnection) {
	const key = request.headers['sec-websocket-key'];
	const upgrade = (request.headers.upgrade || '').toLowerCase();
	const version = request.headers['sec-websocket-version'];

	if (upgrade !== 'websocket' || !key || version !== '13') {
		socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
		return;
	}

	if (options.verify && !options.verify(request)) {
		socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
		return;
	}

	const headers = [
		'HTTP/1.1 101 Switching Protocols',
		'Upgrade: websocket',
		'Connection: Upgrade',
		'Sec-WebSocket-Accept: ' + acceptKey(key)
	];

	const protocol = request.headers['sec-websocket-protocol'];
	if (protocol) headers.push('Sec-WebSocket-Protocol: ' + protocol.split(',')[0].trim());

	socket.write(headers.join('\r\n') + '\r\n\r\n');

	const connection = new WebSocketConnection(socket, request, options);
	onConnection(connection);
	if (head && head.length > 0) connection.onData(head);
}

module.exports = { handleUpgrade, encodeFrame, acceptKey, OPCODES, WebSocketConnection };
