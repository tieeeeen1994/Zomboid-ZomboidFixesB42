package zfix;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.MethodModel;
import java.util.List;
import java.util.zip.ZipFile;

/**
 * Offline check of every patch against a game jar, run by build.sh:
 *   java -cp "zfix-agent.jar;projectzomboid.jar" zfix.Check projectzomboid.jar
 * Per patch: the target method's fingerprint (paste it into the patch when writing one), whether it matches, and the
 * JVM verifier's verdict on the edited class. Exit code 1 when any patch would be skipped or fails to verify.
 */
public final class Check {
   public static void main(String[] args) throws Exception {
      boolean ok = true;
      try (ZipFile jar = new ZipFile(args[0])) {
         for (Patch p : Agent.PATCHES) {
            byte[] bytes = jar.getInputStream(jar.getEntry(p.className() + ".class")).readAllBytes();
            ClassModel cm = ClassFile.of().parse(bytes);
            MethodModel m = cm.methods().stream().filter(p::matches).findFirst().orElse(null);
            if (m == null) {
               System.out.println(p.option() + ": FAIL, no " + p.method() + p.desc());
               ok = false;
               continue;
            }
            String fp = Patch.fingerprint(m);
            if (!p.fingerprints().contains(fp)) {
               System.out.println(p.option() + ": FAIL, fingerprint " + fp + " not in " + p.fingerprints());
               ok = false;
               continue;
            }
            byte[] out = Patch.apply(p.className(), bytes, List.of(p));
            List<VerifyError> errors = ClassFile.of().verify(out);
            System.out.println(p.option() + ": " + (errors.isEmpty() ? "ok" : "FAIL, " + errors) + " (fingerprint " + fp + ")");
            ok &= errors.isEmpty();
         }
      }
      System.exit(ok ? 0 : 1);
   }
}
