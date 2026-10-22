# Gem calculation profile, October 21, 2026

The retained implementation changes only the native macOS host in `macos/src/Host.mm`.
It applies LuaJIT memory settings after `Launch.lua` loads and before `OnInit` runs.
The upstream Lua files and selector behavior remain unchanged.
The selector changes discussed below were experiments and have been removed.

The profile used a local saved Martial Artist build with Falling Thunder as its main skill.
The gem selector queued 334 candidates for the second gem slot.
These headless CPU timings exclude rendering, frame waits, and native host initialization.

The original LuaJIT settings produced repeated machine-code allocation failures in three processes.
One measured run compiled 505,704 traces and flushed the code cache 1,182 times.
That run also recorded 1,182 machine-code allocation failures.
The sampled ranking pass spent approximately 79% of its samples in the JIT compiler.
An unsampled run confirmed the slow ranking time.

Larger code areas avoided these failures in three separate tuning runs.
The original settings also produced one healthy run, which ranked the candidates in 1.99 seconds.
Thus, the improvement addresses an intermittent allocation problem; its size depends on the process.

| Operation | Original settings, failing runs | Larger code areas |
| --- | ---: | ---: |
| Rank all candidates | 20.24–21.37 seconds | 2.66–2.99 seconds |
| Rebuild output | 1.30–1.38 seconds | 0.26–0.37 seconds |
| Rebuild after support toggle | 1.31–1.34 seconds | 0.22–0.27 seconds |
| Hover comparison | 53–59 ms | 8–9 ms |

The macOS host sets `sizemcode=16384` and `maxmcode=65536` through the Lua C API.
LuaJIT expresses both parameters in KiB.
This gives each code area 16 MiB and permits at most 64 MiB across all code areas.
Other platforms retain the previous settings.

The profiler compared scalar outputs with an identical candidate order in both processes.
All 172,331 numeric values matched with relative and absolute tolerances of `1e-9`.
All 10,769 other scalar values also matched.
The comparison included main output, all candidate outputs, and output after a support toggle.
This check covers the selected build and operations.
The experimental startup configuration passed 69 regression checks with the local lightweight headless runner.
Busted was unavailable.
A fourth run using that startup configuration ranked the candidates in 3.22 seconds, with no allocation failures or cache flushes.

The temporary profiler loaded the build into memory and did not save build changes.
It measured elapsed CPU time, collected optional LuaJIT stack samples, and recorded trace allocation failures and cache flushes.
It also saved scalar outputs for comparison, using identical candidate order across processes.

An isolation test on October 22 kept the tuned LuaJIT settings in both cases.
It compared the original selector with the modified selector, using three runs each in alternating order.
The table gives medians; no run had an allocation failure or code-cache flush.

| Measurement | JIT change only | JIT and selector changes |
| --- | ---: | ---: |
| Ranking CPU time | 2.272 seconds | 1.951 seconds |
| Longest calculation batch | 72 ms | 18 ms |
| Calculation batches | 42 | 175 |
| Candidate count | 338 | 334 |

The selector changes reduced ranking CPU time by approximately 14%, giving a 1.16× throughput increase.
The longest batch decreased by approximately 75%.
One additional test disabled DPS sorting: the original selector still used 2.173 seconds of CPU time.
The modified selector used 2.2 ms and queued no candidate calculations.

Shorter batches also increase frame waits during full ranking.
Adding the host's 16 ms wait per batch gives estimated completion times of 2.94 and 4.75 seconds, respectively.
These estimates exclude rendering and other frame work; they are not live UI measurements.
Thus, the selector changes favor responsiveness over full-ranking completion time when DPS sorting remains enabled.
