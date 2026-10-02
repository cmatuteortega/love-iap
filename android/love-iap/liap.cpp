// The native half of love-iap on Android: six C functions that iap.lua calls
// through LuaJIT's FFI, each one forwarding to a static method on
// com.cmatute.loveiap.LoveIap.
//
// It is a plain shared library rather than a Lua C module on purpose. Nothing
// here includes lua.h or links LuaJIT, so it does not care which LÖVE, which
// LuaJIT or which CMake target name the engine build uses -- and iOS can
// export the same six symbols from Swift, so iap.lua is one file for both.
//
// Two things the JNI side has to get right, both learnt from LÖVE's own
// luahttps module (src/libraries/luahttps/src/android/AndroidClient.cpp):
//
// - The JNIEnv and the activity come from SDL, whose exported names changed
//   between SDL2 (LÖVE 11) and SDL3 (LÖVE 12). Both are tried, by dlsym into
//   whichever libSDL is already loaded.
// - The game thread is a native thread attached to the VM, so FindClass on it
//   only sees the system class loader. The class is loaded once through the
//   activity's own loader and kept as a global reference.
//
// And one thing that is easy to miss: these calls come from Lua, not from a
// Java native method, so no JNI frame ever returns and local references would
// pile up for the life of the app. Every entry point pushes a local frame and
// pops it on the way out.

#include <jni.h>
#include <dlfcn.h>

#include <string>

#define LIAP_API extern "C" __attribute__((visibility("default")))

namespace
{

typedef void *(*SDLGetter)(void);

SDLGetter getEnv = nullptr;
SDLGetter getActivity = nullptr;

jclass iapClass = nullptr;
jmethodID mStart, mBuy, mFinish, mRestore, mPoll;

std::string lastEvent;
std::string lastError;

bool bindSDL()
{
	if (getEnv && getActivity)
		return true;

	const char *libs[] = { "libSDL3.so", "libSDL2.so" };
	for (const char *name : libs)
	{
		void *lib = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
		if (!lib)
			lib = dlopen(name, RTLD_NOW);
		if (!lib)
			continue;

		getEnv = (SDLGetter) dlsym(lib, "SDL_GetAndroidJNIEnv");
		getActivity = (SDLGetter) dlsym(lib, "SDL_GetAndroidActivity");
		if (!getEnv || !getActivity)
		{
			getEnv = (SDLGetter) dlsym(lib, "SDL_AndroidGetJNIEnv");
			getActivity = (SDLGetter) dlsym(lib, "SDL_AndroidGetActivity");
		}
		if (getEnv && getActivity)
			return true;
	}

	getEnv = getActivity = nullptr;
	lastError = "SDL's JNI accessors were not found";
	return false;
}

bool cleared(JNIEnv *env)
{
	if (!env->ExceptionCheck())
		return false;
	env->ExceptionDescribe();
	env->ExceptionClear();
	return true;
}

JNIEnv *jni()
{
	return bindSDL() ? (JNIEnv *) getEnv() : nullptr;
}

// Assumes a local frame is already pushed.
bool bindClass(JNIEnv *env)
{
	if (iapClass)
		return true;

	jobject activity = (jobject) getActivity();
	if (!activity)
	{
		lastError = "no activity";
		return false;
	}

	jclass loaderClass = env->FindClass("java/lang/ClassLoader");
	jmethodID loadClass = env->GetMethodID(loaderClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
	jclass activityClass = env->GetObjectClass(activity);
	jmethodID getLoader = env->GetMethodID(activityClass, "getClassLoader", "()Ljava/lang/ClassLoader;");
	jobject loader = env->CallObjectMethod(activity, getLoader);
	jstring name = env->NewStringUTF("com.cmatute.loveiap.LoveIap");
	jclass found = (jclass) env->CallObjectMethod(loader, loadClass, name);

	if (cleared(env) || !found)
	{
		lastError = "class com.cmatute.loveiap.LoveIap is not in the APK";
		return false;
	}

	mStart = env->GetStaticMethodID(found, "start", "(Landroid/app/Activity;Ljava/lang/String;)V");
	mBuy = env->GetStaticMethodID(found, "buy", "(Landroid/app/Activity;Ljava/lang/String;)V");
	mFinish = env->GetStaticMethodID(found, "finish", "(Ljava/lang/String;Z)V");
	mRestore = env->GetStaticMethodID(found, "restore", "()V");
	mPoll = env->GetStaticMethodID(found, "poll", "()Ljava/lang/String;");

	if (cleared(env) || !mStart || !mBuy || !mFinish || !mRestore || !mPoll)
	{
		lastError = "LoveIap is missing a method (Java and native out of step?)";
		return false;
	}

	iapClass = (jclass) env->NewGlobalRef(found);
	return true;
}

// Pushes a frame and binds the class: every entry point starts here and, when
// it returns an env, must end in env->PopLocalFrame(nullptr).
JNIEnv *enter()
{
	JNIEnv *env = jni();
	if (!env)
		return nullptr;
	if (env->PushLocalFrame(16) != 0)
	{
		cleared(env);
		return nullptr;
	}
	if (!bindClass(env))
	{
		env->PopLocalFrame(nullptr);
		return nullptr;
	}
	return env;
}

} // namespace

LIAP_API int liap_start(const char *ids)
{
	JNIEnv *env = enter();
	if (!env)
		return 0;

	jobject activity = (jobject) getActivity();
	jstring csv = env->NewStringUTF(ids ? ids : "");
	env->CallStaticVoidMethod(iapClass, mStart, activity, csv);
	bool ok = !cleared(env);
	if (!ok)
		lastError = "LoveIap.start threw";

	env->PopLocalFrame(nullptr);
	return ok ? 1 : 0;
}

LIAP_API void liap_buy(const char *id)
{
	JNIEnv *env = enter();
	if (!env)
		return;

	jobject activity = (jobject) getActivity();
	jstring jid = env->NewStringUTF(id ? id : "");
	env->CallStaticVoidMethod(iapClass, mBuy, activity, jid);
	cleared(env);

	env->PopLocalFrame(nullptr);
}

LIAP_API void liap_finish(const char *token, int consume)
{
	JNIEnv *env = enter();
	if (!env)
		return;

	jstring jtoken = env->NewStringUTF(token ? token : "");
	env->CallStaticVoidMethod(iapClass, mFinish, jtoken, (jboolean) (consume ? JNI_TRUE : JNI_FALSE));
	cleared(env);

	env->PopLocalFrame(nullptr);
}

LIAP_API void liap_restore(void)
{
	JNIEnv *env = enter();
	if (!env)
		return;

	env->CallStaticVoidMethod(iapClass, mRestore);
	cleared(env);

	env->PopLocalFrame(nullptr);
}

// The returned pointer is valid until the next call; iap.lua copies it with
// ffi.string straight away.
LIAP_API const char *liap_poll(void)
{
	JNIEnv *env = enter();
	if (!env)
		return nullptr;

	const char *out = nullptr;
	jstring line = (jstring) env->CallStaticObjectMethod(iapClass, mPoll);
	if (!cleared(env) && line)
	{
		const char *utf = env->GetStringUTFChars(line, nullptr);
		if (utf)
		{
			lastEvent = utf;
			env->ReleaseStringUTFChars(line, utf);
			out = lastEvent.c_str();
		}
	}

	env->PopLocalFrame(nullptr);
	return out;
}

LIAP_API const char *liap_error(void)
{
	return lastError.c_str();
}
