package network;

enum abstract WebSocketState(Int) from Int to Int
{
	var CONNECTING = 0;
	var OPEN = 1;
	var CLOSING = 2;
	var CLOSED = 3;
}
