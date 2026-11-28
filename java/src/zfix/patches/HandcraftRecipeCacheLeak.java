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
 * The crafting window's recipe cache grows without end (42.22.2, traced 2026-11-28).
 *
 * HandcraftLogic (the crafting window's logic, also the build menu's and each craft action's) declares its own private
 * cachedRecipeInfos / cachedRecipeInfoMap, shadowing BaseCraftingLogic's protected ones, and overrides
 * rebuildCachedRecipeInfo to clear its own. But it fills them through super.createCachedRecipeInfo, which adds every
 * entry to the base class's list and map. So its own list stays empty, and the base list (read by nothing but the base
 * class's rebuildCachedRecipeInfo, which HandcraftLogic never calls) gains one CachedRecipeInfo per recipe (~670) on every
 * rebuild: every container change seen while the window is open, every setRecipes, every finished craft
 * (CLAUDE.md "What costs time with many items"). Nothing is ever released, so a long session with the window open keeps
 * hundreds of thousands of dead entries alive and the garbage collector walks them on every full collection.
 *
 * Fix: rebuildCachedRecipeInfo first clears the base list. The base map stays as it is (every rebuild overwrites each
 * recipe's entry with put), so lookups are unchanged. ponytail: the dropped entries go to the garbage collector instead
 * of the base class's pool (its Release is private to BaseCraftingLogic); pool them only if allocation ever shows up.
 */
public final class HandcraftRecipeCacheLeak {
   private static final ClassDesc BASE = ClassDesc.ofInternalName("zombie/entity/components/crafting/BaseCraftingLogic");
   private static final ClassDesc ARRAY_LIST = ClassDesc.of("java.util.ArrayList");

   public static final Patch PATCH = new Patch(
      "HandcraftRecipeCacheLeak",
      "zombie/entity/components/crafting/recipe/HandcraftLogic",
      "rebuildCachedRecipeInfo", "()V",
      // 42.22.2 (3d39148846), the game's code; PZ Optimization does not replace HandcraftLogic
      Set.of("0dc53a270842d46f"),
      new CodeTransform() {
         @Override
         public void atStart(CodeBuilder b) {
            b.aload(0).getfield(BASE, "cachedRecipeInfos", ARRAY_LIST).invokevirtual(ARRAY_LIST, "clear", MethodTypeDesc.of(ConstantDescs.CD_void));
         }

         @Override
         public void accept(CodeBuilder b, CodeElement e) {
            b.with(e);
         }
      });

   private HandcraftRecipeCacheLeak() {
   }
}
