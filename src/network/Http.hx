package network;

import haxe.Json;

class Http
{
	static var completed:Array<Void->Void> = [];
	#if (!js && target.threaded)
	static var lock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	public static function getJson(url:String, onResult:Dynamic->Void, ?onError:String->Void):Void
	{
		request(url, "GET", null, onResult, onError);
	}

	public static function postJson(url:String, body:Dynamic, onResult:Dynamic->Void, ?onError:String->Void):Void
	{
		request(url, "POST", body, onResult, onError);
	}

	public static function request(url:String, method:String, body:Dynamic, onResult:Dynamic->Void, ?onError:String->Void):Void
	{
		#if (!js && target.threaded)
		sys.thread.Thread.create(function() perform(url, method, body, onResult, onError));
		#else
		perform(url, method, body, onResult, onError);
		#end
	}

	public static function update():Void
	{
		#if (!js && target.threaded)
		lock.acquire();
		var pending:Array<Void->Void> = completed;
		completed = [];
		lock.release();
		#else
		var pending:Array<Void->Void> = completed;
		completed = [];
		#end
		for (callback in pending)
			callback();
	}

	static function finish(callback:Void->Void):Void
	{
		#if (!js && target.threaded)
		lock.acquire();
		completed.push(callback);
		lock.release();
		#else
		completed.push(callback);
		#end
	}

	static function perform(url:String, method:String, body:Dynamic, onResult:Dynamic->Void, onError:String->Void):Void
	{
		#if js
		if (js.Syntax.typeof(js.Syntax.code("fetch")) == "function")
		{
			var init:Dynamic = {method: method, headers: {Accept: "application/json"}};
			if (body != null)
			{
				init.body = Json.stringify(body);
				init.headers = {Accept: "application/json", "Content-Type": "application/json"};
			}
			var promise:js.lib.Promise<Dynamic> = js.Syntax.code("fetch({0}, {1})", url, init);
			promise.then(function(response:Dynamic)
			{
				var text:js.lib.Promise<String> = response.text();
				return text.then(function(content:String)
				{
					if (!response.ok)
					{
						finish(function() if (onError != null) onError('Http Error #${response.status}: $content'));
						return;
					}
					var parsed:Dynamic = null;
					try
					{
						parsed = content.length > 0 ? Json.parse(content) : null;
					}
					catch (e:Dynamic)
					{
						finish(function() if (onError != null) onError("Invalid JSON: " + Std.string(e)));
						return;
					}
					finish(function() onResult(parsed));
				});
			}).catchError(function(error:Dynamic) finish(function() if (onError != null) onError(Std.string(error))));
			return;
		}
		#end

		var http:haxe.Http = new haxe.Http(url);
		http.setHeader("Accept", "application/json");
		var failed:Bool = false;

		http.onData = function(text:String)
		{
			if (failed) return;
			var parsed:Dynamic = null;
			try
			{
				parsed = text != null && text.length > 0 ? Json.parse(text) : null;
			}
			catch (e:Dynamic)
			{
				failed = true;
				finish(function() if (onError != null) onError("Invalid JSON: " + Std.string(e)));
				return;
			}
			finish(function() onResult(parsed));
		};

		http.onError = function(message:String)
		{
			failed = true;
			var text:String = http.responseData;
			finish(function() if (onError != null) onError(text != null && text.length > 0 ? message + ": " + text : message));
		};

		if (body != null)
		{
			http.setHeader("Content-Type", "application/json");
			http.setPostData(Json.stringify(body));
		}

		#if js
		http.async = true;
		#end

		try
		{
			http.request(method == "POST" || body != null);
		}
		catch (e:Dynamic)
		{
			if (!failed) finish(function() if (onError != null) onError(Std.string(e)));
		}
	}
}
