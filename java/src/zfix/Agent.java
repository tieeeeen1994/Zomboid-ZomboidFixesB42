package zfix;

import java.io.Reader;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.ProtectionDomain;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import zfix.patches.CraftInputItems;
import zfix.patches.HandcraftRecipeCacheLeak;

/**
 * Zomboid Fixes B42, Java part: a Java agent that edits single game methods as their classes load.
 *
 * Launcher order: -javaagent:pzopt/agent/pzopt-agent.jar (PZ Optimization, optional) first, then this one, then any
 * other agent (ZombieBuddy). The JVM hands each agent's output to the next, so a class PZ Optimization replaces reaches
 * us as PZ Optimization's class and every other class as the game's own. A patch names the method it edits and the
 * exact code it was written against (Patch.fingerprints): any other code there (a game update, PZ Optimization editing
 * the same method) leaves that method alone and logs why. The transformer is registered without retransform support,
 * like PZ Optimization's, so a later agent that retransforms a class starts from our output.
 *
 * premain must never throw (the game would not start) and must load no game class (PZ Optimization's agent runs the
 * game stock when an agent before it loaded one of its classes; ZombieBuddy's checks may do the same).
 *
 * Files, all in one folder of the game folder (<game>/ZomboidFixesB42/): zfix-agent.jar (this), java.ini (one line per
 * fix, "Option=true" turns it on; a fix whose line is missing or not "true" stays off), agent.log.
 */
public final class Agent {
   /** Every fix. A new one goes here and gets its line in java/java.ini. */
   static final Patch[] PATCHES = { HandcraftRecipeCacheLeak.PATCH, CraftInputItems.PATCH };

   private static Path logFile;

   private Agent() {
   }

   public static void premain(String args, Instrumentation inst) {
      try {
         install(inst);
      } catch (Throwable t) {
         log("not active, the game runs without the Java fixes: " + t);
      }
   }

   private static void install(Instrumentation inst) throws Exception {
      Path dir = Path.of(Agent.class.getProtectionDomain().getCodeSource().getLocation().toURI()).toAbsolutePath().getParent();
      logFile = dir.resolve("agent.log");
      Properties ini = new Properties();
      Path iniFile = dir.resolve("java.ini");
      if (Files.isRegularFile(iniFile)) {
         try (Reader r = Files.newBufferedReader(iniFile, StandardCharsets.UTF_8)) {
            ini.load(r);
         }
      }
      Map<String, List<Patch>> byClass = new HashMap<>();
      List<String> on = new ArrayList<>();
      for (Patch p : PATCHES) {
         if ("true".equalsIgnoreCase(ini.getProperty(p.option(), "").trim())) {
            byClass.computeIfAbsent(p.className(), k -> new ArrayList<>()).add(p);
            on.add(p.option());
         }
      }
      if (byClass.isEmpty()) {
         log("every fix is off in " + iniFile);
         return;
      }
      ClassLoader system = ClassLoader.getSystemClassLoader();
      inst.addTransformer(new ClassFileTransformer() {
         @Override
         public byte[] transform(ClassLoader loader, String name, Class<?> redefined, ProtectionDomain domain, byte[] bytes) {
            if (loader != system || name == null) {
               return null;
            }
            List<Patch> patches = byClass.get(name);
            if (patches == null) {
               return null;
            }
            try {
               return Patch.apply(name, bytes, patches);
            } catch (Throwable t) {
               log(name + " left as it was: " + t);
               return null;
            }
         }
      });
      log("active: " + String.join(", ", on));
   }

   /** stdout of a premain reaches neither console.txt nor the launcher's output, so every line also goes to agent.log. */
   static synchronized void log(String s) {
      System.out.println("[ZomboidFixesB42] " + s);
      if (logFile == null) {
         return;
      }
      try {
         if (Files.isRegularFile(logFile) && Files.size(logFile) > 65536) {
            Files.delete(logFile); // a few lines a launch: start over rather than grow without end
         }
         Files.writeString(logFile, LocalDateTime.now().withNano(0) + " " + s + System.lineSeparator(), StandardCharsets.UTF_8,
            StandardOpenOption.CREATE, StandardOpenOption.APPEND);
      } catch (Throwable ignored) {
      }
   }
}
