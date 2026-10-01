# Shipped custom moves

One ModuleScript per custom move, written by the Move Editor's Studio-only **Tools > Source > Write to
source** (through `scripts/move-writer.py`) and loaded at boot by `Server/Combat/AuthoredMoveLibrary.lua`.
Each file returns a `MoveRecordCodec` record. Safe to hand-edit; writing the move from the editor again
replaces the file. A DataStore record with the same MoveId wins over the file (it is the newer live edit).

This README only exists so git keeps the folder; Rojo ignores `.md` files.
