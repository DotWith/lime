package lime.app;

import lime.system.System;
import lime.system.ThreadFunction;
import lime.system.ThreadPool;
import lime.utils.Log;

/**
	`Future` is an implementation of Futures and Promises, with the exception that
	in addition to "success" and "failure" states (represented as "complete" and "error"),
	Lime `Future` introduces "progress" feedback as well to increase the value of
	`Future` values.

	```haxe
	var future = Image.loadFromFile ("image.png");
	future.onComplete (function (image) { trace ("Image loaded"); });
	future.onProgress (function (loaded, total) { trace ("Loading: " + loaded + ", " + total); });
	future.onError (function (error) { trace (error); });

	Image.loadFromFile ("image.png").then (function (image) {

		return Future.withValue (image.width);

	}).onComplete (function (width) { trace (width); })
	```

	`Future` values can be chained together for asynchronous processing of values.

	If an error occurs earlier in the chain, the error is propagated to all `onError` callbacks.

	`Future` will call `onComplete` callbacks, even if completion occurred before registering the
	callback. This resolves race conditions, so even functions that return immediately can return
	values using `Future`.

	`Future` values are meant to be immutable, if you wish to update a `Future`, you should create one
	using a `Promise`, and use the `Promise` interface to influence the error, complete or progress state
	of a `Future`.
**/
#if !lime_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:allow(lime.app.Promise) /*@:generic*/ class Future<T>
{
	/**
		If the `Future` has finished with an error state, the `error` value
	**/
	public var error(default, null):Dynamic;

	/**
		Whether the `Future` finished with a completion state
	**/
	public var isComplete(default, null):Bool;

	/**
		Whether the `Future` finished with an error state
	**/
	public var isError(default, null):Bool;

	/**
		If the `Future` has finished with a completion state, the completion `value`
	**/
	public var value(default, null):T;

	@:noCompletion private var __completeListeners:Array<T->Void>;
	@:noCompletion private var __errorListeners:Array<Dynamic->Void>;
	@:noCompletion private var __progressListeners:Array<Int->Int->Void>;

	/**
		Create a new `Future` instance.
		@param	work	A function to execute. This comes with the usual limitations in JavaScript.
		See `ThreadFunction.dispatch()` for details.
		@param	async	Whether to run `work` on a background thread, assuming threads are supported.
	**/
	public function new(work:ThreadFunction<Void->T> = null, async:Bool = false)
	{
		if (work != null)
		{
			if (async)
			{
				var promise = new Promise<T>();
				promise.future = this;

				FutureWork.queue(promise, work);
			}
			else
			{
				try
				{
					value = work.dispatch();
					isComplete = true;
				}
				catch (e:Dynamic)
				{
					error = e;
					isError = true;
				}
			}
		}
	}

	/**
		Create a new `Future` instance based on complete and (optionally) error and/or progress `Event` instances
	**/
	public static function ofEvents<T>(onComplete:Event<T->Void>, onError:Event<Dynamic->Void> = null, onProgress:Event<Int->Int->Void> = null):Future<T>
	{
		var promise = new Promise<T>();

		onComplete.add(function(data) promise.complete(data), true);
		if (onError != null) onError.add(function(error) promise.error(error), true);
		if (onProgress != null) onProgress.add(function(progress, total) promise.progress(progress, total), true);

		return promise.future;
	}

	/**
		Register a listener for when the `Future` completes.

		If the `Future` has already completed, this is called immediately with the result
		@param	listener	A callback method to receive the result value
		@return	The current `Future`
	**/
	public function onComplete(listener:T->Void):Future<T>
	{
		if (listener != null)
		{
			if (isComplete)
			{
				listener(value);
			}
			else if (!isError)
			{
				if (__completeListeners == null)
				{
					__completeListeners = new Array();
				}

				__completeListeners.push(listener);
			}
		}

		return this;
	}

	/**
		Register a listener for when the `Future` ends with an error state.

		If the `Future` has already ended with an error, this is called immediately with the error value
		@param	listener	A callback method to receive the error value
		@return	The current `Future`
	**/
	public function onError(listener:Dynamic->Void):Future<T>
	{
		if (listener != null)
		{
			if (isError)
			{
				listener(error);
			}
			else if (!isComplete)
			{
				if (__errorListeners == null)
				{
					__errorListeners = new Array();
				}

				__errorListeners.push(listener);
			}
		}

		return this;
	}

	/**
		Register a listener for when the `Future` updates progress.

		If the `Future` is already completed, this will not be called.
		@param	listener	A callback method to receive the progress value
		@return	The current `Future`
	**/
	public function onProgress(listener:Int->Int->Void):Future<T>
	{
		if (listener != null)
		{
			if (__progressListeners == null)
			{
				__progressListeners = new Array();
			}

			__progressListeners.push(listener);
		}

		return this;
	}

	/**
		Attempts to block on an asynchronous `Future`, returning when it is completed.
		@param	waitTime	(Optional) A timeout before this call will stop blocking
		@return	This current `Future`
	**/
	public function ready(waitTime:Int = -1):Future<T>
	{
		#if js
		if (isComplete || isError)
		{
			return this;
		}
		else
		{
			Log.warn("Cannot block thread in JavaScript");
			return this;
		}
		#else
		if (isComplete || isError)
		{
			return this;
		}
		else
		{
			var time = System.getTimer();
			var end = time + waitTime;

			while (!isComplete && !isError && time <= end)
			{
				#if sys
				Sys.sleep(0.01);
				#end

				time = System.getTimer();
			}

			return this;
		}
		#end
	}

	/**
		Attempts to block on an asynchronous `Future`, returning the completion value when it is finished.
		@param	waitTime	(Optional) A timeout before this call will stop blocking
		@return	The completion value, or `null` if the request timed out or blocking is not possible
	**/
	public function result(waitTime:Int = -1):Null<T>
	{
		ready(waitTime);

		if (isComplete)
		{
			return value;
		}
		else
		{
			return null;
		}
	}

	/**
		Chains two `Future` instances together, passing the result from the first
		as input for creating/returning a new `Future` instance of a new or the same type
	**/
	public function then<U>(next:T->Future<U>):Future<U>
	{
		if (isComplete)
		{
			return next(value);
		}
		else if (isError)
		{
			var future = new Future<U>();
			future.isError = true;
			future.error = error;
			return future;
		}
		else
		{
			var promise = new Promise<U>();

			onError(promise.error);
			onProgress(promise.progress);

			onComplete(function(val)
			{
				var future = next(val);
				future.onError(promise.error);
				future.onComplete(promise.complete);
			});

			return promise.future;
		}
	}

	/**
		Creates a `Future` instance which has finished with an error value
		@param	error	The error value to set
		@return	A new `Future` instance
	**/
	public static function withError(error:Dynamic):Future<Dynamic>
	{
		var future = new Future<Dynamic>();
		future.isError = true;
		future.error = error;
		return future;
	}

	/**
		Creates a `Future` instance which has finished with a completion value
		@param	error	The completion value to set
		@return	A new `Future` instance
	**/
	public static function withValue<T>(value:T):Future<T>
	{
		var future = new Future<T>();
		future.isComplete = true;
		future.value = value;
		return future;
	}
}

#if !lime_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:dox(hide) class FutureWork
{
	private static var threadPool:ThreadPool;
	public static var minThreads(get, set):Int;
	public static var maxThreads(get, set):Int;
	private static var promiseCount:Int = 0;
	private static var promises:Map<Int, Promise<Dynamic>>;

	@:allow(lime.app.Future)
	private static function queue<T>(promise:Promise<T>, work:ThreadFunction<() -> T>):Void
	{
		if (threadPool == null)
		{
			threadPool = new ThreadPool();
			threadPool.doWork = threadPool_doWork;
			threadPool.onComplete.add(threadPool_onComplete);
			threadPool.onError.add(threadPool_onError);
			promises = new Map();
		}

		promises[promiseCount] = cast promise;
		threadPool.queue({ id: promiseCount, work: work });
		promiseCount++;
	}

	// Event Handlers
	private static function threadPool_doWork(state:{ id:Int, work:ThreadFunction<() -> Dynamic> }):Void
	{
		try
		{
			var result = state.work.dispatch();
			threadPool.sendComplete({id: state.id, result: result});
		}
		catch (e:Dynamic)
		{
			threadPool.sendError({id: state.id, error: e});
		}
	}

	private static function threadPool_onComplete(state:Dynamic):Void
	{
		promises[state.id].complete(state.result);
		promises.remove(state.id);
	}

	private static function threadPool_onError(state:Dynamic):Void
	{
		promises[state.id].error(state.error);
		promises.remove(state.id);
	}

	// Getters & Setters
	@:noCompletion private static inline function get_minThreads():Int
	{
		return threadPool.minThreads;
	}

	@:noCompletion private static inline function set_minThreads(value:Int):Int
	{
		return threadPool.minThreads = value;
	}

	@:noCompletion private static inline function get_maxThreads():Int
	{
		return threadPool.maxThreads;
	}

	@:noCompletion private static inline function set_maxThreads(value:Int):Int
	{
		return threadPool.maxThreads = value;
	}
}
