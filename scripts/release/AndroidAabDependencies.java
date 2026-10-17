// SPDX-License-Identifier: Apache-2.0
// Offline inspector. Uses the pinned AGP-generated protobuf classes, not a
// handwritten decoder. Repository URLs are hashed before leaving this process.
import com.android.tools.build.libraries.metadata.*;
import com.google.gson.GsonBuilder;
import com.google.protobuf.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;

class AndroidAabDependencies {
    private static final int MAX_BYTES = 1024 * 1024;
    private static final int MAX_NODES = 3000;
    private static void require(boolean condition, String code) {
        if (!condition) throw new IllegalArgumentException(code);
    }
    private static String hash(byte[] bytes) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }
    private static void knownFields(Message value) {
        require(value.getUnknownFields().asMap().isEmpty(), "unknown_fields");
        for (var field : value.getAllFields().entrySet()) {
            if (field.getKey().getJavaType() != Descriptors.FieldDescriptor.JavaType.MESSAGE) continue;
            if (field.getKey().isRepeated()) {
                for (Object child : (List<?>) field.getValue()) knownFields((Message) child);
            } else knownFields((Message) field.getValue());
        }
    }
    private static void coordinate(String value, boolean empty) {
        require(empty && value.isEmpty() || value.matches("[A-Za-z0-9_.-]{1,200}"), "coordinate");
        require(!value.equals(".") && !value.equals(".."), "coordinate_traversal");
        require(!value.toLowerCase(Locale.ROOT).contains("snapshot") && !value.startsWith("latest."), "floating_version");
    }
    private static void index(int value, int count) {
        require(value >= 0 && value < count, "invalid_index");
    }
    static Map<String, Object> decode(byte[] bytes) throws Exception {
        require(bytes.length > 0 && bytes.length <= MAX_BYTES, "input_size");
        CodedInputStream input = CodedInputStream.newInstance(bytes);
        input.setSizeLimit(MAX_BYTES);
        input.setRecursionLimit(32);
        AppDependencies report = AppDependencies.parseFrom(input);
        require(input.isAtEnd(), "trailing_input");
        knownFields(report);
        require(report.getLibraryCount() > 0 && report.getLibraryCount() <= MAX_NODES, "node_limit");
        require(report.getRepositoriesCount() <= 100 && report.getModuleDependenciesCount() > 0 &&
            report.getModuleDependenciesCount() <= 100, "graph_limit");
        List<Map<String, Object>> libraries = new ArrayList<>();
        Set<String> coordinates = new HashSet<>();
        for (int i = 0; i < report.getLibraryCount(); i++) {
            Library library = report.getLibrary(i);
            require(library.hasMavenLibrary(), "unsupported_library");
            MavenLibrary maven = library.getMavenLibrary();
            coordinate(maven.getGroupId(), false); coordinate(maven.getArtifactId(), false);
            coordinate(maven.getVersion(), false); coordinate(maven.getPackaging(), true);
            coordinate(maven.getClassifier(), true);
            String gav = maven.getGroupId() + ":" + maven.getArtifactId() + ":" + maven.getVersion();
            require(coordinates.add(gav), "duplicate_coordinate");
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("index", i); row.put("group", maven.getGroupId()); row.put("name", maven.getArtifactId());
            row.put("version", maven.getVersion()); row.put("packaging", maven.getPackaging());
            row.put("classifier", maven.getClassifier());
            byte[] digest = library.hasDigests() ? library.getDigests().getSha256().toByteArray() : null;
            require(digest == null || digest.length == 32, "digest_length");
            row.put("sha256", digest == null ? null : HexFormat.of().formatHex(digest));
            if (library.hasRepoIndex()) index(library.getRepoIndex().getValue(), report.getRepositoriesCount());
            row.put("repositoryIndex", library.hasRepoIndex() ? library.getRepoIndex().getValue() : null);
            libraries.add(row);
        }
        int edgeCount = 0;
        Set<Integer> owners = new HashSet<>();
        List<Map<String, Object>> dependencies = new ArrayList<>();
        for (LibraryDependencies dependency : report.getLibraryDependenciesList()) {
            index(dependency.getLibraryIndex(), libraries.size());
            require(owners.add(dependency.getLibraryIndex()), "duplicate_edge_owner");
            for (int to : dependency.getLibraryDepIndexList()) {
                // AGP can emit repeated edges for resolved variants. Retain
                // their multiplicity; indices and total size remain bounded.
                index(to, libraries.size()); edgeCount++;
            }
            dependencies.add(Map.of("libraryIndex", dependency.getLibraryIndex(), "dependencyIndices", dependency.getLibraryDepIndexList()));
        }
        Set<String> moduleNames = new HashSet<>();
        List<Map<String, Object>> modules = new ArrayList<>();
        for (ModuleDependencies module : report.getModuleDependenciesList()) {
            coordinate(module.getModuleName(), false);
            require(moduleNames.add(module.getModuleName()), "duplicate_module");
            for (int to : module.getDependencyIndexList()) {
                index(to, libraries.size()); edgeCount++;
            }
            modules.add(Map.of("name", module.getModuleName(), "dependencyIndices", module.getDependencyIndexList()));
        }
        require(edgeCount <= 30000, "edge_limit");
        List<Map<String, Object>> repositories = new ArrayList<>();
        for (Repository repository : report.getRepositoriesList()) {
            String url = repository.hasMavenRepo() ? repository.getMavenRepo().getUrl() :
                repository.hasIvyRepo() ? repository.getIvyRepo().getUrl() : null;
            require(url != null && !url.isEmpty() && url.length() <= 8192, "repository_kind");
            repositories.add(Map.of("kind", repository.getRepoOneofCase().toString(),
                "urlSha256", hash(url.getBytes(StandardCharsets.UTF_8))));
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("schema", 1); result.put("metadataSha256", hash(bytes));
        result.put("libraries", libraries); result.put("libraryDependencies", dependencies);
        result.put("modules", modules); result.put("repositories", repositories);
        result.put("edgeCount", edgeCount);
        return result;
    }
    private static void rejects(byte[] bytes) throws Exception {
        boolean rejected = false;
        try { decode(bytes); } catch (IllegalArgumentException | InvalidProtocolBufferException expected) { rejected = true; }
        require(rejected, "negative_fixture_accepted");
    }
    private static void test() throws Exception {
        MavenLibrary maven = MavenLibrary.newBuilder().setGroupId("example.test").setArtifactId("library").setVersion("1.0").build();
        Library library = Library.newBuilder().setMavenLibrary(maven).setDigests(
            Library.Digests.newBuilder().setSha256(ByteString.copyFrom(new byte[32]))).build();
        AppDependencies base = AppDependencies.newBuilder().addLibrary(library).addModuleDependencies(
            ModuleDependencies.newBuilder().setModuleName("base").addDependencyIndex(0)).build();
        require(((List<?>) decode(base.toByteArray()).get("libraries")).size() == 1, "positive_fixture");
        require(((List<?>) decode(base.toBuilder().setLibrary(0, library.toBuilder().clearDigests()).build().toByteArray()).get("libraries")).size() == 1, "metadata_only_fixture");
        require((int) decode(base.toBuilder().addLibraryDependencies(LibraryDependencies.newBuilder()
            .setLibraryIndex(0).addLibraryDepIndex(0).addLibraryDepIndex(0)).build().toByteArray()).get("edgeCount") == 3, "repeated_edges_fixture");
        rejects(new byte[]{10, 8, 1}); rejects(new byte[0]); rejects(new byte[MAX_BYTES + 1]);
        rejects(base.toBuilder().addLibrary(library).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().clearMavenLibrary()).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().setMavenLibrary(maven.toBuilder().setVersion("1.+"))).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().setMavenLibrary(maven.toBuilder().setGroupId(".."))).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().setMavenLibrary(maven.toBuilder().setArtifactId("."))).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().setDigests(Library.Digests.newBuilder().setSha256(ByteString.copyFrom(new byte[31])))).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().setRepoIndex(Int32Value.of(0))).build().toByteArray());
        rejects(base.toBuilder().addLibraryDependencies(LibraryDependencies.newBuilder().setLibraryIndex(0).addLibraryDepIndex(1)).build().toByteArray());
        rejects(base.toBuilder().addModuleDependencies(base.getModuleDependencies(0)).build().toByteArray());
        rejects(base.toBuilder().clearModuleDependencies().build().toByteArray());
        rejects(base.toBuilder().setUnknownFields(UnknownFieldSet.newBuilder().addField(99, UnknownFieldSet.Field.newBuilder().addVarint(1).build()).build()).build().toByteArray());
        rejects(base.toBuilder().setLibrary(0, library.toBuilder().setUnknownFields(UnknownFieldSet.newBuilder().addField(99, UnknownFieldSet.Field.newBuilder().addVarint(1).build()).build())).build().toByteArray());
        System.out.println("AAB_PROTOBUF_FIXTURES_PASS 18");
    }
    public static void main(String[] args) {
        try {
            if (args.length == 1 && args[0].equals("--test")) { test(); return; }
            require(args.length == 2, "arguments");
            Path path = Path.of(args[0]);
            require(Files.size(path) > 0 && Files.size(path) <= MAX_BYTES, "input_size");
            String json = new GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(decode(Files.readAllBytes(path)));
            Files.writeString(Path.of(args[1]), json + "\n", StandardOpenOption.CREATE_NEW);
            System.out.println("AAB_PROTOBUF_DECODED");
        } catch (Exception failure) {
            // Input text, repository URLs, and filesystem paths stay out of logs.
            String reason = failure instanceof IllegalArgumentException && failure.getMessage() != null &&
                failure.getMessage().matches("[a-z_]{1,80}") ? failure.getMessage() : failure.getClass().getSimpleName();
            System.err.println("AAB_PROTOBUF_REJECTED:" + reason);
            System.exit(1);
        }
    }
}
