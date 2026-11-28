package zfix.rt;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import zombie.entity.components.resources.ResourceType;
import zombie.inventory.InventoryItem;
import zombie.scripting.entity.components.crafting.InputScript;
import zombie.scripting.objects.Item;

/**
 * Runtime half of patches.CraftInputItems: called by the game at the start of CraftRecipeData.consumeInputFromItems.
 * Loaded by the game's class loader on first use (the agent jar is on the system class path), never from premain.
 *
 * Returns the items of `items` whose script item's full name is one of the input's possible items, grouped by possible
 * item (first occurrence of each name, in the input's order), each group in the list's own order. The game's loop then
 * visits exactly the items it would have acted on, in the same order: it is "for each possible item j, for each item i,
 * act only when i's full name equals j's", so every item it skips was a no-op, and a name listed twice is visited once
 * per listing either way (the second pass finds them in its used set). An empty result makes the method return false at
 * its items.isEmpty() test, which is what the full scan returns when nothing matches (no side effect is skipped: the only
 * one before the loop is usedItems.clear() under clearUsed, so clearUsed calls get the list unchanged).
 *
 * The name index of a list is kept per thread for as long as the same list holds the same items in the same order
 * (identity, size, an order-sensitive hash of identities: one pass of int work per call, instead of names x items string
 * compares). ponytail: one cached list per thread; enough for the crafting window's rebuild, which runs every recipe
 * against the same allItems list. Small lists are not worth indexing and pass through.
 */
public final class CraftItemIndex {
   private static final int MIN_ITEMS = 32;

   private static final class Cache {
      List<InventoryItem> list;
      int size;
      int hash;
      final HashMap<String, ArrayList<InventoryItem>> byName = new HashMap<>();
   }

   private static final ThreadLocal<Cache> CACHE = ThreadLocal.withInitial(Cache::new);

   private CraftItemIndex() {
   }

   public static List<InventoryItem> filter(InputScript input, List<InventoryItem> items, boolean clearUsed) {
      if (clearUsed || input == null || items == null || items.size() < MIN_ITEMS || input.getResourceType() != ResourceType.Item) {
         return items;
      }
      Cache c = CACHE.get();
      int n = items.size();
      int h = 1;
      for (int i = 0; i < n; i++) {
         h = 31 * h + System.identityHashCode(items.get(i));
      }
      if (c.list != items || c.size != n || c.hash != h) {
         c.byName.clear();
         for (int i = 0; i < n; i++) {
            InventoryItem item = items.get(i);
            Item script = item.getScriptItem();
            if (script != null) { // the game's loop would throw on it; it can never match
               c.byName.computeIfAbsent(script.getFullName(), k -> new ArrayList<>()).add(item);
            }
         }
         c.list = items;
         c.size = n;
         c.hash = h;
      }
      List<Item> possible = input.getPossibleInputItems();
      ArrayList<String> names = new ArrayList<>(possible.size());
      for (int j = 0; j < possible.size(); j++) {
         names.add(possible.get(j).getFullName());
      }
      return gather(c.byName, names);
   }

   /** The groups of the wanted names, each name once, in the order the names are listed. */
   static <T> ArrayList<T> gather(HashMap<String, ArrayList<T>> byName, List<String> names) {
      ArrayList<T> out = new ArrayList<>();
      HashSet<String> seen = new HashSet<>();
      for (String name : names) {
         if (seen.add(name)) {
            ArrayList<T> group = byName.get(name);
            if (group != null) {
               out.addAll(group);
            }
         }
      }
      return out;
   }

   /**
    * Self-check (java -cp zfix-agent.jar zfix.rt.CraftItemIndex): the game's loop visits (j, i) pairs where names match;
    * the filtered list must make the same loop visit the same items in the same order, for random lists.
    */
   public static void main(String[] args) {
      java.util.Random r = new java.util.Random(42);
      for (int t = 0; t < 2000; t++) {
         int types = 1 + r.nextInt(12);
         List<String> items = new ArrayList<>();
         for (int i = 0, n = r.nextInt(80); i < n; i++) {
            items.add("T" + r.nextInt(types) + "#" + i);
         }
         List<String> wanted = new ArrayList<>();
         for (int j = 0, n = r.nextInt(6); j < n; j++) {
            wanted.add("T" + r.nextInt(types + 2)); // includes absent types and repeats
         }
         HashMap<String, ArrayList<String>> byName = new HashMap<>();
         for (String it : items) {
            byName.computeIfAbsent(it.substring(0, it.indexOf('#')), k -> new ArrayList<>()).add(it);
         }
         List<String> filtered = gather(byName, wanted);
         if (!visits(items, wanted).equals(visits(filtered, wanted))) {
            throw new AssertionError("order differs for " + items + " / " + wanted);
         }
      }
      System.out.println("CraftItemIndex: ok");
   }

   private static List<String> visits(List<String> items, List<String> wanted) {
      List<String> v = new ArrayList<>();
      for (String w : wanted) {
         for (String it : items) {
            if (it.substring(0, it.indexOf('#')).equals(w)) {
               v.add(w + ":" + it);
            }
         }
      }
      return v;
   }
}
