package lime.system;

import lime.app.Application;
import lime.app.Event;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Thread;
#elseif cpp
import cpp.vm.Deque;
import cpp.vm.Thread;
#elseif neko
import neko.vm.Deque;
import neko.vm.Thread;
#end
#if !lime_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
class BackgroundWorker
{
	private static inline var MESSAGE_COMPLETE = "__COMPLETE__";
	private static inline var MESSAGE_ERROR = "__ERROR__";
	private static inline var MESSAGE_CANCEL = "__CANCEL__";

	public var canceled(default, null):Bool;
	public var completed(default, null):Bool;
	public var doWork = new Event<Dynamic->Void>();
	public var onComplete = new Event<Dynamic->Void>();
	public var onError = new Event<Dynamic->Void>();
	public var onProgress = new Event<Dynamic->Void>();

	@:noCompletion private var __runMessage:Dynamic;
	#if (target.threaded || cpp || neko)
	@:noCompletion private var __messageQueue:Deque<Dynamic>;
	@:noCompletion private var __workerThread:Thread;
	#end

	public function new() {}

	public function cancel():Void
	{
		canceled = true;

		#if (target.threaded || cpp || neko)
		if (__workerThread != null)
		{
			// Canceling an event eventually stops the
			// `dispatch()` function, thereby stopping the
			// background thread. But this will be undone
			// if the event is reused, such as by calling
			// `run()` again and creating a new thread. Then
			// the old thread will continue to completion.

			// `lime.app.Event` wasn't designed with thread
			// safety as a priority.
			doWork.cancel();

			// To ensure `doWork` stays canceled, we need
			// to make a new instance instead of reusing
			// this one.
			var clone = new Event<Dynamic -> Void>();

			// Synchronize everything except `canceled`.
			clone.__listeners = doWork.__listeners.copy();
			clone.__repeat = doWork.__repeat.copy();
			@:privateAccess clone.__priorities = doWork.__priorities.copy();
			doWork = clone;

			// Send a message for `isThreadCanceled()`
			// to receive.
			__workerThread.sendMessage(MESSAGE_CANCEL);

			__workerThread = null;
			__messageQueue = null;
		}
		#end
	}

	#if (target.threaded || cpp || neko)
	public inline function isThreadCanceled():Bool
	{
		return Thread.current().readMessage(false) == MESSAGE_CANCEL;
	}
	#end

	public function run(message:Dynamic = null):Void
	{
		cancel();

		canceled = false;
		completed = false;
		__runMessage = message;

		#if (target.threaded || cpp || neko)
		__messageQueue = new Deque<Dynamic>();
		__workerThread = Thread.create(__doWork);

		// TODO: Better way to do this

		if (Application.current != null)
		{
			Application.current.onUpdate.add(__update);
		}
		#else
		__doWork();
		#end
	}

	public function sendComplete(message:Dynamic = null):Void
	{
		#if (target.threaded || cpp || neko)
		if (__messageQueue != null)
		{
			__messageQueue.add(MESSAGE_COMPLETE);
			__messageQueue.add(message);
		}
		#else
		completed = true;

		if (!canceled)
		{
			canceled = true;
			onComplete.dispatch(message);
		}
		#end
	}

	public function sendError(message:Dynamic = null):Void
	{
		#if (target.threaded || cpp || neko)
		if (__messageQueue != null)
		{
			__messageQueue.add(MESSAGE_ERROR);
			__messageQueue.add(message);
		}
		#else
		if (!canceled)
		{
			canceled = true;
			onError.dispatch(message);
		}
		#end
	}

	public function sendProgress(message:Dynamic = null):Void
	{
		#if (target.threaded || cpp || neko)
		if (__messageQueue != null)
		{
			__messageQueue.add(message);
		}
		#else
		if (!canceled)
		{
			onProgress.dispatch(message);
		}
		#end
	}

	@:noCompletion private function __doWork():Void
	{
		doWork.dispatch(__runMessage);

		// #if (target.threaded || cpp || neko)
		//
		// __messageQueue.add (MESSAGE_COMPLETE);
		//
		// #else
		//
		// if (!canceled) {
		//
		// canceled = true;
		// onComplete.dispatch (null);
		//
		// }
		//
		// #end
	}

	@:noCompletion private function __update(deltaTime:Int):Void
	{
		#if (target.threaded || cpp || neko)
		var message = __messageQueue.pop(false);

		if (message != null)
		{
			if (message == MESSAGE_ERROR)
			{
				Application.current.onUpdate.remove(__update);

				if (!canceled)
				{
					canceled = true;
					onError.dispatch(__messageQueue.pop(false));
				}
			}
			else if (message == MESSAGE_COMPLETE)
			{
				completed = true;
				Application.current.onUpdate.remove(__update);

				if (!canceled)
				{
					canceled = true;
					onComplete.dispatch(__messageQueue.pop(false));
				}
			}
			else
			{
				if (!canceled)
				{
					onProgress.dispatch(message);
				}
			}
		}
		#end
	}
}
