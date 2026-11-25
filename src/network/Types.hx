package network;

typedef PlayerInfo =
{
	var id:Int;
	var name:String;
	var data:Dynamic;
}

typedef RoomSummary =
{
	var id:String;
	var name:String;
	var players:Int;
	var maxPlayers:Int;
	var locked:Bool;
	var started:Bool;
	var meta:Dynamic;
}

typedef RoomOptions =
{
	@:optional var name:String;
	@:optional var maxPlayers:Int;
	@:optional var password:String;
	@:optional var meta:Dynamic;
	@:optional var isPrivate:Bool;
}

typedef ScoreEntry =
{
	var name:String;
	var score:Float;
	var data:Dynamic;
	var time:Float;
}

typedef NetworkError =
{
	var code:String;
	var message:String;
}
