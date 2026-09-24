#include <SDL3/SDL.h>
#include <cassert>
#include <chrono>
#include <fstream>

// Feed deterministic window coordinates to the real Lua mouse API, without
// opening a window or moving the user's cursor.
static float mouseX = 300, mouseY = 180;
static SDL_MouseButtonFlags testMouseState(float* x, float* y) {
    *x = mouseX; *y = mouseY;
    return 0;
}
static void testWarpMouse(SDL_Window*, float x, float y) {
    mouseX = x; mouseY = y;
}
#include "../src/SubScript.mm"

#define SDL_GetMouseState testMouseState
#define SDL_WarpMouseInWindow testWarpMouse
#include "../src/Host.mm"
#undef SDL_GetMouseState
#undef SDL_WarpMouseInWindow

struct EngineRegressionTests {
    static void run(const char* fonts) {
        Host host;
        host.L = luaL_newstate();
        luaL_openlibs(host.L);
        host.registerApi();
        auto lua = [&](const char* script) {
            if (luaL_dostring(host.L, script) != LUA_OK) {
                std::fprintf(stderr, "%s\n", lua_tostring(host.L, -1));
                std::abort();
            }
        };

        char temp[] = "/tmp/pob-engine-regression-XXXXXX";
        assert(mkdtemp(temp));
        lua_pushstring(host.L, temp);
        lua_setglobal(host.L, "testRoot");
        lua(R"(
            local folder = testRoot .. '/folder'
            assert(MakeDir(folder))
            local ok, err = MakeDir(folder)
            assert(not ok and type(err) == 'string')
            local file = assert(io.open(folder .. '/keep.txt', 'w'))
            file:write('keep'); file:close()
            ok, err = RemoveDir(folder)
            assert(not ok and type(err) == 'string')
            file = assert(io.open(folder .. '/keep.txt')); file:close()
            assert(RemoveDir(folder, true))
            ok, err = RemoveDir(folder)
            assert(not ok and type(err) == 'string')
            assert(MakeDir(folder)); assert(RemoveDir(folder))
            file = assert(io.open(testRoot .. '/file', 'w')); file:close()
            ok, err = MakeDir(testRoot .. '/file/child')
            assert(not ok and type(err) == 'string')
        )");
        fs::remove_all(temp);

        for (double percent : {0.0, 100.0, 125.0, 150.0, 200.0, 250.0}) {
            host.dpiScaleOverride = percent;
            const double scale = percent > 0 ? percent / 100 : 1;
            mouseX = 300; mouseY = 180;
            lua_settop(host.L, 0);
            Host::l_GetCursorPos(host.L);
            assert(std::abs(lua_tonumber(host.L, -2) - 300 / scale) < 0.001);
            assert(std::abs(lua_tonumber(host.L, -1) - 180 / scale) < 0.001);
            // The mock consumes the handle without dereferencing it.
            host.window = reinterpret_cast<SDL_Window*>(1);
            Host::l_SetCursorPos(host.L);
            host.window = nullptr;
            assert(std::abs(mouseX - 300) < 0.001 && std::abs(mouseY - 180) < 0.001);
            lua_settop(host.L, 0);
        }

        host.fontRenderer.setFontsDirectory(fonts);
        for (int height : {16, 20, 25, 32, 40}) {
            // Every returned index must be a UTF-8 boundary, including mixed
            // ASCII, 2/3/4-byte characters, color escapes and multiple lines.
            const std::string text = "A\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80Z";
            const std::unordered_set<int> boundaries{0, 1, 3, 6, 10, 11};
            const int width = host.fontRenderer.stringWidth(height, "VAR", text);
            for (int x = -2; x <= width + 2; ++x) {
                const int index = host.fontRenderer.stringCursorIndex(height, "VAR", text, x, 0);
                assert(boundaries.contains(index));
                const int second = host.fontRenderer.stringCursorIndex(height, "VAR", "x\n" + text, x, height + 1);
                assert(boundaries.contains(second - 2));
                const int colored = host.fontRenderer.stringCursorIndex(height, "VAR", "^7" + text, x, 0);
                assert(boundaries.contains(colored - 2));
            }
            const auto accented = host.fontRenderer.stringWidth(height, "VAR", "\xc3\xa9");
            assert(accented > 0);
            assert(host.fontRenderer.stringWidth(height, "VAR", "\xe4\xb8\xad") == accented);
            assert(host.fontRenderer.stringWidth(height, "VAR", "\xf0\x9f\x98\x80") == accented);
            assert(host.fontRenderer.stringWidth(height, "VAR", "\xc3\xa9\xc3\xa9") == accented * 2);
            // Truncated and malformed input must not hang or read past the end.
            for (const auto& invalid : {std::string("\xc3"), std::string("\xf0\x80"), std::string("\xed\xa0\x80")}) {
                host.fontRenderer.stringWidth(height, "VAR", invalid);
                assert(host.fontRenderer.stringCursorIndex(height, "VAR", invalid, 1000, 0) == invalid.size());
            }
        }

        SDL_Surface* surface = SDL_CreateSurface(300, 60, SDL_PIXELFORMAT_RGBA32);
        assert(surface);
        SDL_Renderer* renderer = SDL_CreateSoftwareRenderer(surface);
        assert(renderer);
        {
            FontRenderer font;
            font.setFontsDirectory(fonts);
            auto render = [&](const std::string& text) {
                SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
                SDL_RenderClear(renderer);
                font.drawString(renderer, 0, 0, "LEFT", 25, "VAR", text, {1, 1, 1, 1});
                SDL_RenderPresent(renderer);
                const auto* begin = static_cast<unsigned char*>(surface->pixels);
                return std::vector<unsigned char>(begin, begin + surface->pitch * surface->h);
            };
            const auto accented = render("A\xc3\xa9Z");
            assert(accented != render(""));
            assert(accented == render("A\xe4\xb8\xadZ"));
            assert(accented == render("A\xf0\x9f\x98\x80Z"));
        }
        SDL_DestroyRenderer(renderer);
        SDL_DestroySurface(surface);

        // A normally completed synchronous callback must still deliver results.
        {
            SubScriptWorker worker;
            assert(worker.start(host.L, "return GetWorkDir()", "GetWorkDir", "", nullptr));
            {
                std::unique_lock lock(worker.mutex);
                assert(worker.cv.wait_for(lock, std::chrono::seconds(2), [&] { return worker.funcWaiting; }));
                worker.funcReturns = std::make_unique<ValueNode>();
                worker.funcReturns->type = ValueType::Number;
                worker.funcReturns->number = 42;
                worker.funcWaiting = false;
                worker.cv.notify_all();
                assert(worker.cv.wait_for(lock, std::chrono::seconds(2), [&] { return worker.finished; }));
            }
            worker.stopWorker();
            assert(lua_tonumber(worker.L, -1) == 42);
        }

        for (int i = 0; i < 20; ++i) {
            SubScriptWorker worker;
            assert(worker.start(host.L, "GetWorkDir()", "GetWorkDir", "", nullptr));
            {
                std::unique_lock lock(worker.mutex);
                assert(worker.cv.wait_for(lock, std::chrono::seconds(2), [&] { return worker.funcWaiting; }));
            }
            worker.stopWorker();
            assert(!worker.running && worker.finished && !worker.worker.joinable());
            worker.stopWorker(); // Repeated cleanup must remain harmless.
        }
        std::puts("Native engine regression tests passed.");
    }
};

int main(int argc, char** argv) {
    assert(argc == 2);
    EngineRegressionTests::run(argv[1]);
}
