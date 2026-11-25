# Orbis XEMU

[xemu](https://github.com/xemu-project/xemu) (emulador do Xbox original, QEMU 10.2) para PS4 com
GoldHEN, compilado no WSL Ubuntu. **Um repositorio so, um comando so**: tudo que o build precisa
(toolchain, Mesa/RADV, dependencias, patches, empacotamento) esta aqui, sem depender das arvores do
DolphinPS4, Crema ou Resonance.

Estado (v00.15 + audio): boota a BIOS e roda o Halo 2 ate a tela de titulo, com o DualShock 4, a
cerca de 1 fps e com erros de renderizacao. O audio (driver SDL3 sobre `sceAudioOut`) esta escrito
mas ainda nao foi testado no console. Achados e proximos passos em [docs/PORTING.md](docs/PORTING.md).

## Como compilar (do zero ate o .pkg)

No **Ubuntu do WSL2**, com o OpenOrbis do PacBrew em `/opt/pacbrew/ps4/openorbis`:

```bash
cd ~/orbis-xemu          # este repositorio, no disco do WSL (nao em /mnt/c)
bash build.sh doctor     # diz exatamente o que falta instalar
bash build.sh all 00.16  # baixa, compila tudo e gera out/xemu-ps4-v00.16.pkg
```

A primeira vez leva algumas horas (libc++, Mesa e dependencias); depois so o `xemu` e o `pkg` rodam
de novo, e o `ninja` e incremental. Se uma etapa falhar, o `build.sh` mostra o log; corrija e rode
o mesmo comando de novo: o que ja esta pronto e pulado.

| Comando | O que faz |
|---|---|
| `bash build.sh doctor` | confere o ambiente (e corrige permissoes e fim de linha de zips do Windows) |
| `bash build.sh fetch` | xemu no commit de `patches/BASE.txt` + `xemu-ps4.patch`, Mesa 26.0.8 + `mesa/mesa-ps4.patch`, libdrm |
| `bash build.sh toolchain` | libc++ 21 e sysroot do PS4 |
| `bash build.sh mesa` | RADV (Vulkan) para a GPU do PS4 |
| `bash build.sh deps [nome]` | zlib, glslang, pixman, glib, SDL3 (com o driver de audio) |
| `bash build.sh xemu [reconfigure\|clean]` | configura, compila e gera o `eboot.bin` |
| `bash build.sh pkg 00.16` | empacota `out/xemu-ps4-v00.16.pkg` |
| `bash build.sh status` | o que ja foi feito |

Tudo que e gerado fica fora do repositorio, em `~/orbis-xemu-work` (mude com `ORBIS_WORK`); logs em
`~/orbis-xemu-work/logs/<etapa>.log`.

### Depois do build

- Enviar ao PS4 (no **Windows**, Git Bash, nao no WSL): `tools/upload-to-console.sh out/xemu-ps4-vXX.YY.pkg`
- Instalar pelo Package Installer do GoldHEN. Title ID `XEMU00001`; atualizar instala por cima e
  mantem o `/data/xemu`.
- Se o app travar: `tools/crashlog.sh` baixa os logs do console e simboliza o crash.
- Mexeu no codigo do xemu? Edite em `~/orbis-xemu-work/src/xemu` (branch `ps4`), compile com
  `bash build.sh xemu` e salve no repositorio com `tools/save-patch.sh "mensagem"`.

## Estrutura

```
build.sh        o unico comando (doctor, all, fetch, toolchain, mesa, deps, xemu, pkg, status)
config.sh       todos os caminhos e versoes num lugar so
stages/         uma etapa por arquivo (o que o build.sh chama)
toolchain/      compiladores (ps4-cc, ps4-c++), libc++, headers de libc, link script
mesa/           patch do Mesa, winsys do PS4 (ac_ps4_drm.c), headers de overlay
port/           runtime do PS4: heap, crash log, sampler, rede, string
patches/        xemu-ps4.patch, sdl3-ps4.patch (audio) e BASE.txt (commit do xemu)
package/        make-pkg.sh, icones (sce_sys) e o gerador de arte
tools/          crashlog, upload para o console, save-patch
docs/           PORTING.md: arquitetura, medicoes e proximos passos
out/            o .pkg final (ignorado pelo git)
```

## Funcionalidades

- Video: renderer Vulkan do NV2A sobre o RADV/GNM; o frontend `ui/ps4` apresenta a imagem no VideoOut
- CPU: TCG do QEMU; DSP: interpretador (o JIT em Rust ainda nao tem build para PS4)
- Audio: driver SDL3 `ps4` sobre `sceAudioOut` (`patches/sdl3-ps4.patch`), com o `dummy` como reserva
- Entrada: DualShock 4 (ScePad) como gamepad virtual SDL na porta 1
- UI: HUD em ImGui (FPS, carga de GPU e threads, avisos)

## On the console

| Path | What |
|---|---|
| `/data/xemu/bios` | MCPX boot ROM (512 bytes) and flash BIOS (256 KiB or 1 MiB), found by size |
| `/data/xemu/hdd/xbox_hdd.qcow2` | hard disk image |
| `/data/xemu/games` | games (XISO `.iso`) |
| `/data/xemu` | `xemu.toml`, `eeprom.bin`, `xemu.log`, `boot-trace.log`, `crash.log` |

Title ID `XEMU00001`. Install the pkg with GoldHEN's Package Installer.

## License

GPL-2.0-or-later, as xemu/QEMU ([LICENSE](LICENSE)): `patches/xemu-ps4.patch` is a modification of
xemu, and the PS4 frontend it adds (`ui/ps4`) is part of that work. The PS4 runtime in `port/` and
the toolchain scripts come from the Resonance / DolphinPS4 / Crema ports; `mesa/winsys/ac_ps4_drm.c`
is the RADV winsys of the PS4 Mesa port (MIT, as Mesa); `port/third_party` keeps its own notices.
No Microsoft BIOS, boot ROM, Sony system files or games are included: supply your own.
