/*
 * Compile (load without running) Lua files with a given LuaJIT library, to prove
 * that the LuaJIT an app bundle ships can parse the Lua it ships. Built and run
 * by tools/macos/check_bundled_lua.sh.
 *
 *   load_lua <libluajit.dylib>      (Lua file paths on stdin, one per line)
 *
 * Prints the library's LuaJIT version, a FAIL line with the error for each file
 * that doesn't load, and a summary; exits non-zero if any file failed. The
 * library is dlopen'ed by path so the check exercises exactly that file, not
 * some other LuaJIT this tool happens to find (Homebrew's luajit command, for
 * one, has LuaJIT linked in statically).
 */
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef struct lua_State lua_State;

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <libluajit.dylib> < lua-file-list\n", argv[0]);
		return 2;
	}
	void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		fprintf(stderr, "error: %s\n", dlerror());
		return 2;
	}
	lua_State *(*newstate)(void) = (lua_State *(*)(void))dlsym(lib, "luaL_newstate");
	void (*openlibs)(lua_State *) = (void (*)(lua_State *))dlsym(lib, "luaL_openlibs");
	int (*loadfile)(lua_State *, const char *) = (int (*)(lua_State *, const char *))dlsym(lib, "luaL_loadfile");
	int (*loadstring)(lua_State *, const char *) = (int (*)(lua_State *, const char *))dlsym(lib, "luaL_loadstring");
	int (*pcall)(lua_State *, int, int, int) = (int (*)(lua_State *, int, int, int))dlsym(lib, "lua_pcall");
	const char *(*tolstring)(lua_State *, int, size_t *) = (const char *(*)(lua_State *, int, size_t *))dlsym(lib, "lua_tolstring");
	void (*settop)(lua_State *, int) = (void (*)(lua_State *, int))dlsym(lib, "lua_settop");
	if (!newstate || !openlibs || !loadfile || !loadstring || !pcall || !tolstring || !settop) {
		fprintf(stderr, "error: %s does not export the Lua C API\n", argv[1]);
		return 2;
	}

	lua_State *L = newstate();
	openlibs(L);
	if (loadstring(L, "return jit and jit.version or _VERSION") == 0 && pcall(L, 0, 1, 0) == 0) {
		const char *version = tolstring(L, -1, NULL);
		printf("%s (%s)\n", version ? version : "unknown version", argv[1]);
	}
	settop(L, 0);

	char path[4096];
	int count = 0, failed = 0;
	while (fgets(path, sizeof path, stdin)) {
		path[strcspn(path, "\n")] = '\0';
		if (!path[0])
			continue;
		count++;
		if (loadfile(L, path) != 0) {
			const char *err = tolstring(L, -1, NULL);
			printf("FAIL %s\n", err ? err : path);
			failed++;
		}
		settop(L, 0);
	}
	printf("%d Lua files, %d failed to load\n", count, failed);
	return failed || !count ? 1 : 0;
}
