# Differential Comparison and Three-Way Merge Algorithms

Anvil includes a complete suite of differential comparison and merge reconciliation algorithms implemented from first principles in Object Pascal (`src/diff` and `src/merge`). This document explains the mathematical foundations, data structures, and edge-case behaviors of these algorithms.

---

## 1. Myers Shortest Edit Script (SES) Algorithm

Eugene W. Myers' 1986 paper ("An $O(ND)$ Difference Algorithm and Its Variations") models the sequence comparison problem as finding the shortest path through an edit graph.

### The Edit Graph Model
Let string $A$ have length $N$ (horizontal axis $x \in [0, N]$) and string $B$ have length $M$ (vertical axis $y \in [0, M]$):
- Moving right $(x \to x+1, y)$ represents **deleting** a character/line from $A$ (cost 1).
- Moving down $(x, y \to y+1)$ represents **inserting** a character/line into $B$ (cost 1).
- Moving diagonally $(x \to x+1, y \to y+1)$ occurs with zero cost whenever $A[x+1] = B[y+1]$ (**matching lines / snake**).

```
   (0,0) ---- delete A[1] ----> (1,0)
     |                            |
  insert                        insert
   B[1]                          B[1]
     v                            v
   (0,1) ---- delete A[1] ----> (1,1)
         \                      /
          \-- match snake -----/
```

### Diagonal Navigation and Farthest Reaching $D$-Paths
Diagonals are indexed by $k = x - y \in [-M, N]$. For each step count $D = 0, 1, 2, \dots, N+M$, Anvil computes the furthest-reaching point along each diagonal $k$:
1. If $k = -D$ or ($k \neq D$ and $V[k-1] < V[k+1]$), the search comes from diagonal $k+1$ (vertical downward step: insertion).
2. Otherwise, the search comes from diagonal $k-1$ (horizontal rightward step: deletion).
3. The snake is extended greedily along diagonal $k$ as long as $A[x+1] = B[y+1]$.

Anvil stores the snapshot array $V_D$ at each step in dynamic memory, reconstructing the optimal edit script in reverse once $(N, M)$ is reached.

---

## 2. Patience Diff Algorithm

While Myers' algorithm minimizes the total edit count $D$, it can produce unnatural diffs on structured programming source code where curly braces, blank lines, or standard keywords match ambiguously across unrelated methods.

Anvil implements the **Patience Diff** algorithm (`src/diff/anvil_patience.pas`) designed by Bram Cohen:

### Step 1: Unique Line Extraction
1. Count the occurrences of every line in document $A$ and document $B$.
2. Filter for lines that appear **exactly once** in $A$ and **exactly once** in $B$ (unique common lines).

### Step 2: Longest Common Increasing Subsequence (LCIS)
Map each unique common line to its index pair $(Pos_A, Pos_B)$. Anvil computes the LCIS of $Pos_B$ values relative to ordered $Pos_A$ using patient sorting:
- Stacks of cards are maintained via binary search ($O(K \log K)$ where $K$ is the number of unique matches).
- Pointers track the predecessors of each element.
- The resulting sequence forms rigid, semantically unambiguous anchor points.

### Step 3: Recursive Sub-problem Resolution
For each slice bounded between consecutive anchor points:
- If both slices are non-empty, Patience diff is called recursively.
- If no unique lines remain in a sub-slice, the fallback Myers algorithm is applied.

---

## 3. Rename and Copy Detection

Anvil detects renamed and copied files across trees (`src/diff/anvil_rename.pas`) without requiring explicit filesystem tracking:
1. **Exact Hash Matching**: Unmodified files that changed paths match with 100% similarity if their object IDs are identical.
2. **Content Similarity Scoring**: For files with different IDs, Anvil tokenizes file contents into lines and calculates the Dice/Jaccard similarity coefficient:
   $$\text{Similarity}(A, B) = \frac{2 \times |Lines(A) \cap Lines(B)|}{|Lines(A)| + |Lines(B)|} \times 100$$
3. Candidate pairs exceeding the configurable similarity threshold (default: 50%) are emitted as `TTreeDelta` records with `eoRename` or `eoCopy` operations.

---

## 4. Lowest Common Ancestor (LCA) and Merge Bases

To merge two diverged branches $A$ and $B$, Anvil locates their merge base in the commit DAG (`src/merge/anvil_lca.pas`):
1. **Generation Numbering**: Every commit records its topological generation number (maximum depth from repository root).
2. **Priority Queue Traversal**: Ancestors are explored starting from the branch heads using a max-heap ordered by generation number.
3. **Bitmask Set Classification**: Commits visited exclusively along branch $A$'s line of descent are tagged with flag `1`; commits along branch $B$'s line are tagged with flag `2`.
4. Commits carrying both flags (`1 or 2 = 3`) represent candidate common ancestors.
5. Anvil tests whether candidate ancestors are subsumed by other candidates, isolating the unique lowest common ancestor.

---

## 5. Three-Way File and Tree Reconciliation

Given base ancestor $O$, target branch $A$ (ours), and incoming branch $B$ (theirs):

### Line-Level Reconciliation (`anvil_merge3.pas`)
1. Compute difference $O \to A$ and difference $O \to B$.
2. Align changes into monotonic line chunks:
   - **Case 1**: Changed in $A$, unchanged in $B \implies$ accept edit from $A$.
   - **Case 2**: Changed in $B$, unchanged in $A \implies$ accept edit from $B$.
   - **Case 3**: Changed identically in both $A$ and $B \implies$ accept edit without conflict.
   - **Case 4**: Overlapping differing modifications in $A$ and $B \implies$ emit conflict block:
     ```
     <<<<<<< HEAD
     Our version
     ||||||| BASE
     Ancestor version
     =======
     Their version
     >>>>>>> branch-name
     ```

### Tree-Level Reconciliation (`anvil_merge_tree.pas`)
Traverses directory structures recursively:
- Cleanly added, deleted, or updated entries are automatically committed into the index at Stage 0.
- Conflicting files are preserved with all three variations staged (Stage 1 = Ancestor, Stage 2 = Ours, Stage 3 = Theirs), enabling inspection and resolution with `anvil diff` or `anvil checkout --ours / --theirs`.
