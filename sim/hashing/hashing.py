import numpy as np
import matplotlib.pyplot as plt

# -------------------- Parametri --------------------
MEM_SIZE     = 8 * 1024 * 1024      # 8 MiB
BLOCK_SIZE   = 32
ASSOC        = 2
CACHE_SIZE   = 8 * 1024             # 8 KiB
NUM_SETS     = CACHE_SIZE // (ASSOC * BLOCK_SIZE)   # 128
OFFSET_BITS  = 5                    # log2(32)
SET_MASK     = NUM_SETS - 1

print(f"Block size      : {BLOCK_SIZE} B")
print(f"Numero di set   : {NUM_SETS}")
print(f"Blocchi totali  : {MEM_SIZE // BLOCK_SIZE}")
print(f"Densità attesa  : {(MEM_SIZE // BLOCK_SIZE) // NUM_SETS} blocchi/set\n")


# -------------------- Hash leggero migliorato --------------------
def sv_hash_index(addr: int) -> int:
    block_addr = addr >> OFFSET_BITS          # 18 bit

    h  =  block_addr        & 0x7F            # [6:0]
    h ^= (block_addr >>  3) & 0x7F            # [9:3]
    h ^= (block_addr >>  7) & 0x7F            # [13:7]
    h ^= (block_addr >> 11) & 0x7F            # [17:11]
    h ^= (block_addr >> 14) & 0x0F            # {3'b0, [17:14]}
    h ^= (block_addr >>  2) & 0x7F            # [8:2]

    return h & SET_MASK


def classic_index(addr: int) -> int:
    return (addr >> OFFSET_BITS) & SET_MASK


# -------------------- Tabella primi 64 blocchi --------------------
print("=" * 72)
print(f"{'Blocco':>6}  {'Indirizzo':>12}  {'Classico':>10}  {'Hash SV':>10}")
print("-" * 72)

for i in range(16):
    addr = (0x20100 + i) * BLOCK_SIZE
    set_classic = classic_index(addr)
    set_hash    = sv_hash_index(addr)
    print(f"{i:6d}  0x{addr:08x}  {set_classic:02x}  {set_hash:02x}")

print("=" * 72)
print()

addr = 0x3cd1af
set_classic = classic_index(addr)
set_hash    = sv_hash_index(addr)
print(f"{i:6d}  0x{addr:08x}  {set_classic:02x}  {set_hash:02x}")

# -------------------- Calcolo istogramma completo --------------------
num_blocks = MEM_SIZE // BLOCK_SIZE
counts = np.zeros(NUM_SETS, dtype=np.int64)

for b in range(num_blocks):
    addr = b * BLOCK_SIZE
    s = sv_hash_index(addr)
    counts[s] += 1

print("Risultato istogramma completo:")
print(f"  Min / Max / Media : {counts.min()} / {counts.max()} / {counts.mean():.1f}")
print(f"  Deviazione std    : {counts.std():.2f}")
print(f"  Rapporto max/min  : {counts.max() / counts.min():.4f}")


# -------------------- Istogramma --------------------
fig, ax = plt.subplots(figsize=(12, 5))
ax.bar(range(NUM_SETS), counts, width=1.0, color='darkorange', edgecolor='none', alpha=0.9)
ax.axhline(counts.mean(), color='gray', linestyle='--', linewidth=1.2,
           label=f'Media = {counts.mean():.0f}')
ax.set_title(f'Istogramma completo – Hash SystemVerilog migliorato\n'
             f'Blocchi da {BLOCK_SIZE} B su tutto lo spazio 8 MiB', fontsize=13)
ax.set_xlabel('Set index')
ax.set_ylabel('Numero di blocchi di memoria')
ax.set_ylim(0, counts.max() * 1.15)
ax.legend()
ax.grid(axis='y', alpha=0.3)
plt.tight_layout()
plt.savefig('histogram_32B_full_8MiB.png', dpi=150, bbox_inches='tight')
plt.close()

print("\nPlot salvato come: histogram_32B_full_8MiB.png")