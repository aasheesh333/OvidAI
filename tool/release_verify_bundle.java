// JDK source launcher: verifies every AAB payload entry, not just META-INF.
// Unlike `jarsigner -verify` without -strict, an unsigned entry cannot pass.
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.HexFormat;
import java.util.Set;
import java.util.TreeSet;
import java.util.jar.JarFile;

class ReleaseVerifyBundle {
    public static void main(String[] args) throws Exception {
        String expected = args[1].replace(":", "").toLowerCase();
        boolean production = !expected.equals("-");
        if (production && !expected.matches("[0-9a-f]{64}")) {
            throw new SecurityException("Required production certificate SHA-256 is absent/invalid");
        }
        Set<String> observed = new TreeSet<>();
        int count = 0;
        try (JarFile jar = new JarFile(Path.of(args[0]).toFile(), true)) {
            var entries = jar.entries();
            byte[] buffer = new byte[65536];
            while (entries.hasMoreElements()) {
                var entry = entries.nextElement();
                if (entry.isDirectory()) continue;
                String name = entry.getName().toUpperCase(java.util.Locale.ROOT);
                // Only actual signature metadata is exempt, not arbitrary META-INF content.
                if (name.matches("META-INF/(MANIFEST\\.MF|[^/]+\\.(SF|RSA|DSA|EC)|SIG-[^/]+)")) continue;
                try (var stream = jar.getInputStream(entry)) {
                    while (stream.read(buffer) != -1) { /* triggers JarVerifier */ }
                }
                var signers = entry.getCodeSigners();
                if (signers == null || signers.length != 1) {
                    throw new SecurityException("Unsigned or multi-signed bundle payload entry");
                }
                var cert = (X509Certificate) signers[0].getSignerCertPath().getCertificates().get(0);
                cert.checkValidity();
                String fingerprint = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
                if (production && (cert.getSubjectX500Principal().getName().toLowerCase().contains("cn=android debug")
                        || !fingerprint.equals(expected))) {
                    throw new SecurityException("Debug or unexpected bundle signer");
                }
                observed.add(fingerprint);
                count++;
            }
        }
        if (count == 0 || observed.size() != 1) throw new SecurityException("No consistent verified bundle signer");
        System.out.println("[\"" + observed.iterator().next() + "\"]");
    }
}
