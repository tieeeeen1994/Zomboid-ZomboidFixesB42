package zfix;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.Instruction;
import java.lang.classfile.MethodModel;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * One fix: an edit of one method of one game class.
 *
 * option       its line in java.ini
 * className    internal name, e.g. zombie/entity/components/crafting/recipe/HandcraftLogic
 * method, desc the method's name and JVM descriptor
 * fingerprints the code the edit was written for (Patch.fingerprint of the method as it arrives: the game's, or PZ
 *              Optimization's when it replaces that class); anything else is left alone
 * edit         the change, applied to the method's code
 */
public record Patch(String option, String className, String method, String desc, Set<String> fingerprints, CodeTransform edit) {
   static byte[] apply(String name, byte[] bytes, List<Patch> patches) {
      ClassFile cf = ClassFile.of();
      ClassModel cm = cf.parse(bytes);
      ClassTransform all = null;
      for (Patch p : patches) {
         MethodModel m = cm.methods().stream().filter(p::matches).findFirst().orElse(null);
         if (m == null) {
            Agent.log(p.option() + ": skipped, " + name + "." + p.method() + p.desc() + " does not exist in this game");
            continue;
         }
         String fp = fingerprint(m);
         if (!p.fingerprints().contains(fp)) {
            Agent.log(p.option() + ": skipped, " + name + "." + p.method() + " is not the code this fix was written for"
               + " (a game update, or another mod changed it; fingerprint " + fp + ")");
            continue;
         }
         ClassTransform t = ClassTransform.transformingMethodBodies(p::matches, p.edit());
         all = all == null ? t : all.andThen(t);
         Agent.log(p.option() + ": on");
      }
      return all == null ? null : cf.transformClass(cm, all);
   }

   boolean matches(MethodModel m) {
      return m.methodName().equalsString(method) && m.methodType().equalsString(desc);
   }

   /** The method's instructions with their symbolic operands, so the same code reads the same whatever the constant pool. */
   static String fingerprint(MethodModel m) {
      String code = m.code().map(c -> c.elementStream().filter(Instruction.class::isInstance).map(Object::toString)
         .collect(Collectors.joining("\n"))).orElse("");
      try {
         byte[] sha = MessageDigest.getInstance("SHA-256").digest(code.getBytes(StandardCharsets.UTF_8));
         return HexFormat.of().formatHex(sha, 0, 8);
      } catch (Exception e) {
         throw new IllegalStateException(e);
      }
   }
}
