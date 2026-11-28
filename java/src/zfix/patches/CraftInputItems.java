package zfix.patches;

import java.lang.classfile.CodeBuilder;
import java.lang.classfile.CodeElement;
import java.lang.classfile.CodeTransform;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.util.Set;
import zfix.Patch;

/**
 * Crafting checks slow down with every item nearby (42.22.2, traced 2026-11-28).
 *
 * CraftRecipeData.consumeInputFromItems decides whether an input line is satisfied by the given items with
 *   for each possible item type j of the input: for each item i: if i's full name equals j's ... (string equals)
 * so one input costs (possible types) x (items) compares. The crafting window runs it for every recipe (~670) against
 * every item of the window's containers on each rebuild (each container change seen while it is open, each finished
 * craft: onStopCraft -> sortRecipeList -> rebuildCachedRecipeInfo -> createCachedRecipeInfo -> canPerform), and each craft
 * action does it again for its recipe. With thousands of items around, a finished craft froze the game for a moment,
 * longer with more items. Tag inputs (any knife, any hammer) list dozens of types, which multiplies it.
 *
 * Fix: the method starts with items = CraftItemIndex.filter(input, items, clearUsed), which keeps only the items whose
 * type the input accepts (same order, see CraftItemIndex for why the result is identical), from an index built once per
 * list state. The game's loop and everything after it is unchanged.
 */
public final class CraftInputItems {
   private static final ClassDesc INPUT_SCRIPT = ClassDesc.ofInternalName("zombie/scripting/entity/components/crafting/InputScript");
   private static final ClassDesc LIST = ClassDesc.of("java.util.List");
   private static final ClassDesc INDEX = ClassDesc.ofInternalName("zfix/rt/CraftItemIndex");

   public static final Patch PATCH = new Patch(
      "CraftInputItems",
      "zombie/entity/components/crafting/recipe/CraftRecipeData",
      "consumeInputFromItems",
      "(Lzombie/scripting/entity/components/crafting/InputScript;Ljava/util/List;ZLzombie/entity/components/crafting/recipe/CraftRecipeData$CacheData;ZLzombie/characters/IsoGameCharacter;)Z",
      // 42.22.2 (3d39148846), the game's code; PZ Optimization does not replace CraftRecipeData
      Set.of("a6ef437960d4a0a6"),
      new CodeTransform() {
         @Override
         public void atStart(CodeBuilder b) {
            // locals: 0 this, 1 input, 2 items, 3 testOnly, 4 cacheData, 5 clearUsed, 6 character
            b.aload(1).aload(2).iload(5)
               .invokestatic(INDEX, "filter", MethodTypeDesc.of(LIST, INPUT_SCRIPT, LIST, ConstantDescs.CD_boolean))
               .astore(2);
         }

         @Override
         public void accept(CodeBuilder b, CodeElement e) {
            b.with(e);
         }
      });

   private CraftInputItems() {
   }
}
