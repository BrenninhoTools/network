package network;

import network.Types;

class Leaderboard
{
	public var baseUrl(default, null):String;

	public function new(baseUrl:String)
	{
		this.baseUrl = StringTools.endsWith(baseUrl, "/") ? baseUrl.substr(0, baseUrl.length - 1) : baseUrl;
	}

	public function submit(board:String, name:String, score:Float, ?extra:Dynamic, ?callback:Int->Void, ?onError:String->Void):Void
	{
		Http.postJson('$baseUrl/scores/${StringTools.urlEncode(board)}', {name: name, score: score, data: extra}, function(result:Dynamic)
		{
			if (callback != null) callback(result != null && result.rank != null ? result.rank : -1);
		}, onError);
	}

	public function top(board:String, limit:Int = 10, callback:Array<ScoreEntry>->Void, ?onError:String->Void):Void
	{
		Http.getJson('$baseUrl/scores/${StringTools.urlEncode(board)}?limit=$limit', function(result:Dynamic)
		{
			callback(result != null && result.scores != null ? result.scores : []);
		}, onError);
	}

	public function rooms(callback:Array<RoomSummary>->Void, ?onError:String->Void):Void
	{
		Http.getJson('$baseUrl/rooms', function(result:Dynamic)
		{
			callback(result != null && result.rooms != null ? result.rooms : []);
		}, onError);
	}
}
