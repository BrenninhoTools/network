package network;

import haxe.io.Bytes;

private enum SocketEvent
{
	Opened;
	Text(text:String);
	Binary(bytes:Bytes);
	Closed(code:Int, reason:String);
	Failed(message:String);
}

class WebSocket
{
	public static var verifyCertificates:Bool = true;
	public static var connectTimeout:Float = 10;

	public var url(default, null):String;
	public var state(default, null):WebSocketState = CLOSED;
	public var protocols:Array<String>;
	public var headers:Map<String, String>;

	public var onOpen:Void->Void;
	public var onMessage:String->Void;
	public var onBinary:Bytes->Void;
	public var onClose:Int->String->Void;
	public var onError:String->Void;

	var events:Array<SocketEvent> = [];

	#if js
	var native:js.html.WebSocket;
	#elseif target.threaded
	var socket:sys.net.Socket;
	var writeLock:sys.thread.Mutex = new sys.thread.Mutex();
	var eventLock:sys.thread.Mutex = new sys.thread.Mutex();
	var closeSent:Bool = false;
	#end

	public function new(url:String, ?protocols:Array<String>, ?headers:Map<String, String>)
	{
		this.url = url;
		this.protocols = protocols != null ? protocols : [];
		this.headers = headers != null ? headers : new Map();
	}

	public function connect():Void
	{
		if (state == CONNECTING || state == OPEN) return;
		state = CONNECTING;

		#if js
		try
		{
			native = protocols.length > 0 ? new js.html.WebSocket(url, protocols) : new js.html.WebSocket(url);
		}
		catch (e:Dynamic)
		{
			push(Failed(Std.string(e)));
			push(Closed(1006, Std.string(e)));
			return;
		}
		native.binaryType = js.html.BinaryType.ARRAYBUFFER;
		native.onopen = function(_) push(Opened);
		native.onmessage = function(event:js.html.MessageEvent)
		{
			if (Std.isOfType(event.data, String)) push(Text(event.data));
			else push(Binary(Bytes.ofData(event.data)));
		};
		native.onerror = function(_) push(Failed("WebSocket error"));
		native.onclose = function(event:js.html.CloseEvent) push(Closed(event.code, event.reason));
		#elseif target.threaded
		closeSent = false;
		sys.thread.Thread.create(run);
		#else
		push(Failed("WebSocket needs threads or JavaScript on this target"));
		push(Closed(1006, "Unsupported target"));
		#end
	}

	public function send(text:String):Bool
	{
		if (state != OPEN) return false;
		#if js
		native.send(text);
		return true;
		#elseif target.threaded
		return writeFrame(0x1, Bytes.ofString(text));
		#else
		return false;
		#end
	}

	public function sendBytes(bytes:Bytes):Bool
	{
		if (state != OPEN) return false;
		#if js
		native.send(bytes.getData());
		return true;
		#elseif target.threaded
		return writeFrame(0x2, bytes);
		#else
		return false;
		#end
	}

	public function close(code:Int = 1000, reason:String = ""):Void
	{
		if (state == CLOSED || state == CLOSING) return;
		var wasConnecting:Bool = state == CONNECTING;
		state = CLOSING;
		#if js
		if (native != null) native.close(code, reason);
		#elseif target.threaded
		if (wasConnecting || socket == null)
		{
			shutdown();
			push(Closed(code, reason));
			return;
		}
		var text:Bytes = Bytes.ofString(reason.length > 120 ? reason.substr(0, 120) : reason);
		var payload:Bytes = Bytes.alloc(2 + text.length);
		payload.set(0, (code >> 8) & 0xFF);
		payload.set(1, code & 0xFF);
		payload.blit(2, text, 0, text.length);
		closeSent = true;
		writeFrame(0x8, payload, true);
		sys.thread.Thread.create(function()
		{
			Sys.sleep(2);
			shutdown();
		});
		#end
	}

	public function update():Void
	{
		var pending:Array<SocketEvent> = takeEvents();
		for (event in pending)
		{
			switch (event)
			{
				case Opened:
					state = OPEN;
					if (onOpen != null) onOpen();
				case Text(text):
					if (onMessage != null) onMessage(text);
				case Binary(bytes):
					if (onBinary != null) onBinary(bytes);
				case Failed(message):
					if (onError != null) onError(message);
				case Closed(code, reason):
					var wasClosed:Bool = state == CLOSED;
					state = CLOSED;
					#if (!js && target.threaded)
					shutdown();
					#end
					if (!wasClosed && onClose != null) onClose(code, reason);
			}
		}
	}

	function push(event:SocketEvent):Void
	{
		#if (!js && target.threaded)
		eventLock.acquire();
		events.push(event);
		eventLock.release();
		#else
		events.push(event);
		#end
	}

	function takeEvents():Array<SocketEvent>
	{
		#if (!js && target.threaded)
		eventLock.acquire();
		var pending:Array<SocketEvent> = events;
		events = [];
		eventLock.release();
		return pending;
		#else
		var pending:Array<SocketEvent> = events;
		events = [];
		return pending;
		#end
	}

	#if (!js && target.threaded)
	function run():Void
	{
		try
		{
			handshake();
		}
		catch (e:Dynamic)
		{
			shutdown();
			push(Failed(Std.string(e)));
			push(Closed(1006, Std.string(e)));
			return;
		}

		push(Opened);

		var input:haxe.io.Input = socket.input;
		input.bigEndian = true;
		var fragments:haxe.io.BytesBuffer = null;
		var fragmentOpcode:Int = 0;

		try
		{
			while (true)
			{
				var b0:Int = input.readByte();
				var b1:Int = input.readByte();
				var fin:Bool = (b0 & 0x80) != 0;
				var opcode:Int = b0 & 0x0F;
				var masked:Bool = (b1 & 0x80) != 0;
				var length:Int = b1 & 0x7F;

				if (length == 126)
				{
					length = input.readUInt16();
				}
				else if (length == 127)
				{
					var high:Int = input.readInt32();
					var low:Int = input.readInt32();
					if (high != 0 || low < 0) throw "Frame too large";
					length = low;
				}

				var mask:Bytes = masked ? input.read(4) : null;
				var payload:Bytes = length > 0 ? input.read(length) : Bytes.alloc(0);
				if (mask != null)
					for (i in 0...payload.length)
						payload.set(i, payload.get(i) ^ mask.get(i & 3));

				switch (opcode)
				{
					case 0x0:
						if (fragments == null) throw "Unexpected continuation frame";
						fragments.add(payload);
						if (fin)
						{
							deliver(fragmentOpcode, fragments.getBytes());
							fragments = null;
						}
					case 0x1, 0x2:
						if (fin) deliver(opcode, payload);
						else
						{
							fragmentOpcode = opcode;
							fragments = new haxe.io.BytesBuffer();
							fragments.add(payload);
						}
					case 0x8:
						var code:Int = payload.length >= 2 ? (payload.get(0) << 8) | payload.get(1) : 1005;
						var reason:String = payload.length > 2 ? payload.getString(2, payload.length - 2) : "";
						if (!closeSent)
						{
							closeSent = true;
							writeFrame(0x8, payload.sub(0, payload.length >= 2 ? 2 : 0), true);
						}
						shutdown();
						push(Closed(code, reason));
						return;
					case 0x9:
						writeFrame(0xA, payload, true);
					case 0xA:
					default:
						throw "Unknown opcode " + opcode;
				}
			}
		}
		catch (e:Dynamic)
		{
			var wasClosing:Bool = closeSent;
			shutdown();
			if (Std.isOfType(e, haxe.io.Eof) || wasClosing) push(Closed(wasClosing ? 1000 : 1006, wasClosing ? "" : "Connection lost"));
			else
			{
				push(Failed(Std.string(e)));
				push(Closed(1006, Std.string(e)));
			}
		}
	}

	function deliver(opcode:Int, payload:Bytes):Void
	{
		if (opcode == 0x1) push(Text(payload.toString()));
		else push(Binary(payload));
	}

	function handshake():Void
	{
		var parsed:WebSocketUrl = WebSocketUrl.parse(url);

		#if (cpp || hl || neko || eval || java || python || php)
		if (parsed.secure)
		{
			var secure:sys.ssl.Socket = new sys.ssl.Socket();
			secure.verifyCert = verifyCertificates;
			secure.setHostname(parsed.host);
			socket = secure;
		}
		else socket = new sys.net.Socket();
		#else
		if (parsed.secure) throw "wss is not supported on this target";
		socket = new sys.net.Socket();
		#end

		socket.setTimeout(connectTimeout);
		socket.connect(new sys.net.Host(parsed.host), parsed.port);
		socket.setFastSend(true);

		var keyBytes:Bytes = Bytes.alloc(16);
		for (i in 0...16)
			keyBytes.set(i, Std.random(256));
		var key:String = haxe.crypto.Base64.encode(keyBytes);

		var request:StringBuf = new StringBuf();
		request.add('GET ${parsed.resource} HTTP/1.1\r\n');
		request.add('Host: ${parsed.host}${parsed.defaultPort ? "" : ":" + parsed.port}\r\n');
		request.add("Upgrade: websocket\r\n");
		request.add("Connection: Upgrade\r\n");
		request.add('Sec-WebSocket-Key: $key\r\n');
		request.add("Sec-WebSocket-Version: 13\r\n");
		if (protocols.length > 0) request.add('Sec-WebSocket-Protocol: ${protocols.join(", ")}\r\n');
		for (name => value in headers)
			request.add('$name: $value\r\n');
		request.add("\r\n");

		socket.output.writeString(request.toString());
		socket.output.flush();

		var status:String = socket.input.readLine();
		if (status.indexOf(" 101") < 0) throw "Handshake failed: " + status;

		var accept:String = null;
		while (true)
		{
			var line:String = socket.input.readLine();
			if (line.length == 0) break;
			var colon:Int = line.indexOf(":");
			if (colon > 0 && StringTools.trim(line.substr(0, colon)).toLowerCase() == "sec-websocket-accept") accept = StringTools.trim(line.substr(colon + 1));
		}

		var expected:String = haxe.crypto.Base64.encode(haxe.crypto.Sha1.make(Bytes.ofString(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
		if (accept != expected) throw "Handshake failed: invalid Sec-WebSocket-Accept";

		socket.setTimeout(86400);
	}

	function writeFrame(opcode:Int, payload:Bytes, force:Bool = false):Bool
	{
		if (socket == null || (!force && state != OPEN)) return false;

		var length:Int = payload.length;
		var header:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		header.addByte(0x80 | opcode);

		if (length < 126) header.addByte(0x80 | length);
		else if (length < 65536)
		{
			header.addByte(0x80 | 126);
			header.addByte((length >> 8) & 0xFF);
			header.addByte(length & 0xFF);
		}
		else
		{
			header.addByte(0x80 | 127);
			for (i in 0...4)
				header.addByte(0);
			header.addByte((length >>> 24) & 0xFF);
			header.addByte((length >> 16) & 0xFF);
			header.addByte((length >> 8) & 0xFF);
			header.addByte(length & 0xFF);
		}

		var mask:Array<Int> = [for (i in 0...4) Std.random(256)];
		for (value in mask)
			header.addByte(value);

		var masked:Bytes = Bytes.alloc(length);
		for (i in 0...length)
			masked.set(i, payload.get(i) ^ mask[i & 3]);
		header.add(masked);

		var frame:Bytes = header.getBytes();
		writeLock.acquire();
		try
		{
			socket.output.writeFullBytes(frame, 0, frame.length);
			socket.output.flush();
		}
		catch (e:Dynamic)
		{
			writeLock.release();
			return false;
		}
		writeLock.release();
		return true;
	}

	function shutdown():Void
	{
		var current:sys.net.Socket = socket;
		socket = null;
		if (current == null) return;
		try
		{
			current.shutdown(true, true);
		}
		catch (e:Dynamic) {}
		try
		{
			current.close();
		}
		catch (e:Dynamic) {}
	}
	#end
}

private class WebSocketUrl
{
	public var secure:Bool;
	public var host:String;
	public var port:Int;
	public var resource:String;
	public var defaultPort:Bool;

	public function new() {}

	public static function parse(url:String):WebSocketUrl
	{
		var result:WebSocketUrl = new WebSocketUrl();
		var pattern:EReg = ~/^(wss?):\/\/(\[[^\]]+\]|[^:\/?#]+)(?::(\d+))?([^#]*)/i;
		if (!pattern.match(url)) throw "Invalid WebSocket url: " + url;
		result.secure = pattern.matched(1).toLowerCase() == "wss";
		result.host = pattern.matched(2);
		if (StringTools.startsWith(result.host, "[")) result.host = result.host.substr(1, result.host.length - 2);
		var port:String = pattern.matched(3);
		result.defaultPort = port == null;
		result.port = port != null ? Std.parseInt(port) : (result.secure ? 443 : 80);
		var resource:String = pattern.matched(4);
		result.resource = resource == null || resource.length == 0 ? "/" : (StringTools.startsWith(resource, "/") ? resource : "/" + resource);
		return result;
	}
}
