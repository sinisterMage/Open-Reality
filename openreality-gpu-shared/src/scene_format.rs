/// ORSB (OpenReality Scene Bundle) binary format definitions.
///
/// The format is designed for zero-copy loading in WASM and efficient
/// streaming from Julia's scene export.

/// Magic bytes at the start of every .orsb file.
pub const ORSB_MAGIC: [u8; 4] = *b"ORSB";
pub const ORSB_VERSION: u32 = 1;

/// File header (32 bytes).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct OrsbHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub flags: u32,
    pub num_entities: u32,
    pub num_meshes: u32,
    pub num_textures: u32,
    pub num_materials: u32,
    pub num_animations: u32,
}

/// Section identifiers in the table of contents.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SectionType {
    EntityGraph = 1,
    Transforms = 2,
    Meshes = 3,
    Materials = 4,
    Textures = 5,
    Lights = 6,
    Cameras = 7,
    Colliders = 8,
    RigidBodies = 9,
    Animations = 10,
    Skeletons = 11,
    Particles = 12,
    PhysicsConfig = 13,
}

/// Table of contents entry.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TocEntry {
    pub section_type: u32,
    pub offset: u64,
    pub size: u64,
}

/// Component mask bitfield — indicates which components an entity has.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ComponentMask(pub u64);

impl ComponentMask {
    pub const TRANSFORM: u64 = 1 << 0;
    pub const MESH: u64 = 1 << 1;
    pub const MATERIAL: u64 = 1 << 2;
    pub const CAMERA: u64 = 1 << 3;
    pub const POINT_LIGHT: u64 = 1 << 4;
    pub const DIR_LIGHT: u64 = 1 << 5;
    pub const COLLIDER: u64 = 1 << 6;
    pub const RIGIDBODY: u64 = 1 << 7;
    pub const ANIMATION: u64 = 1 << 8;
    pub const SKELETON: u64 = 1 << 9;
    pub const PARTICLE: u64 = 1 << 10;
    pub const AUDIO_SOURCE: u64 = 1 << 11;
    pub const AUDIO_LISTENER: u64 = 1 << 12;
    pub const IBL: u64 = 1 << 13;

    pub fn has(&self, flag: u64) -> bool {
        self.0 & flag != 0
    }

    pub fn set(&mut self, flag: u64) {
        self.0 |= flag;
    }
}

/// Entity entry in the entity graph section.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct EntityEntry {
    pub entity_id: u64,
    /// Index of parent entity in the entity array, or u32::MAX if root.
    pub parent_index: u32,
    pub component_mask: ComponentMask,
    pub transform_index: u32,
    pub mesh_index: u32,
    pub material_index: u32,
    pub camera_index: u32,
    pub light_index: u32,
    pub collider_index: u32,
    pub rigidbody_index: u32,
    pub animation_index: u32,
    pub skeleton_index: u32,
    pub particle_index: u32,
}

/// Serialized transform data.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TransformData {
    pub position: [f64; 3],
    pub rotation: [f64; 4], // quaternion (w, x, y, z)
    pub scale: [f64; 3],
}

/// Mesh header in the mesh section.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MeshHeader {
    pub vertex_count: u32,
    pub index_count: u32,
    pub has_bone_data: u32,
    pub _pad: u32,
}

/// Serialized material data.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MaterialData {
    pub color: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
    pub opacity: f32,
    pub alpha_cutoff: f32,
    pub emissive_factor: [f32; 4],
    pub clearcoat: f32,
    pub clearcoat_roughness: f32,
    pub subsurface: f32,
    pub subsurface_color: [f32; 3],
    pub parallax_height_scale: f32,
    /// Index into texture array, or i32::MAX (-1 as unsigned) if no texture.
    pub albedo_texture_index: i32,
    pub normal_texture_index: i32,
    pub metallic_roughness_texture_index: i32,
    pub ao_texture_index: i32,
    pub emissive_texture_index: i32,
    pub height_texture_index: i32,
    pub clearcoat_texture_index: i32,
    pub _pad: i32,
}

/// Texture header in the texture section.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TextureHeader {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    /// 0 = raw RGBA, 1 = PNG compressed, 2 = Basis Universal
    pub compression: u32,
    pub data_size: u64,
}

/// Collider shape types.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShapeType {
    AABB = 0,
    Sphere = 1,
    Capsule = 2,
    OBB = 3,
    ConvexHull = 4,
    Compound = 5,
}

/// RigidBody type.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyType {
    Static = 0,
    Kinematic = 1,
    Dynamic = 2,
}

/// CCD mode.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CCDMode {
    None = 0,
    Swept = 1,
}

/// Serialized rigid body data.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RigidBodyData {
    pub body_type: u8,
    pub ccd_mode: u8,
    pub _pad1: u8,
    pub _pad2: u8,
    pub mass: f64,
    pub restitution: f32,
    pub friction: f64,
    pub linear_damping: f64,
    pub angular_damping: f64,
}

/// Animation interpolation mode.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InterpolationMode {
    Step = 0,
    Linear = 1,
    CubicSpline = 2,
}

/// Animation target property.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TargetProperty {
    Position = 0,
    Rotation = 1,
    Scale = 2,
}

/// Physics world configuration.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PhysicsConfigData {
    pub gravity: [f64; 3],
    pub fixed_dt: f64,
    pub max_substeps: u32,
    pub solver_iterations: u32,
    pub position_correction: f32,
    pub slop: f32,
}

/// Parsed point light from the lights section.
#[derive(Clone, Debug)]
pub struct PointLightParsed {
    pub position: [f32; 3],
    pub color: [f32; 3],
    pub intensity: f32,
    pub range: f32,
}

/// Parsed directional light from the lights section.
#[derive(Clone, Debug)]
pub struct DirLightParsed {
    pub direction: [f32; 3],
    pub color: [f32; 3],
    pub intensity: f32,
}

/// Parsed camera from the cameras section.
#[derive(Clone, Copy, Debug)]
pub struct CameraParsed {
    pub fov: f32,
    pub near: f32,
    pub far: f32,
    pub aspect: f32,
}

/// Parsed collider from the colliders section.
#[derive(Clone, Copy, Debug)]
pub struct ColliderParsed {
    pub shape_type: u8,
    pub shape_data: [f32; 3],
    pub offset: [f32; 3],
    pub is_trigger: bool,
}

/// Parsed animation channel.
#[derive(Clone, Debug)]
pub struct AnimationChannelParsed {
    pub target_entity_index: u32,
    pub target_property: TargetProperty,
    pub interpolation: InterpolationMode,
    pub times: Vec<f32>,
    pub values: Vec<f64>,
}

/// Parsed animation clip.
#[derive(Clone, Debug)]
pub struct AnimationClipParsed {
    pub name: String,
    pub duration: f32,
    pub channels: Vec<AnimationChannelParsed>,
}

/// Parsed animation component (contains clips + playback state).
#[derive(Clone, Debug)]
pub struct AnimationParsed {
    pub clips: Vec<AnimationClipParsed>,
    pub active_clip: i32,
    pub playing: bool,
    pub looping: bool,
    pub speed: f32,
}

/// Parsed mesh data.
#[derive(Clone, Debug)]
pub struct MeshParsed {
    pub positions: Vec<f32>,
    pub normals: Vec<f32>,
    pub uvs: Vec<f32>,
    pub indices: Vec<u32>,
    pub bone_weights: Option<Vec<f32>>,
    pub bone_indices: Option<Vec<u16>>,
}

/// Parsed texture data.
#[derive(Clone, Debug)]
pub struct TextureParsed {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub compression: u32,
    pub data: Vec<u8>,
}

/// Complete parsed ORSB scene — all sections.
#[derive(Clone, Debug)]
pub struct ParsedScene {
    pub header: OrsbHeader,
    pub entity_ids: Vec<u64>,
    pub parent_indices: Vec<Option<usize>>,
    pub component_masks: Vec<ComponentMask>,
    pub mesh_indices: Vec<Option<usize>>,
    pub material_indices: Vec<Option<usize>>,
    pub transforms: Vec<TransformData>,
    pub meshes: Vec<MeshParsed>,
    pub materials: Vec<MaterialData>,
    pub textures: Vec<TextureParsed>,
    pub point_lights: Vec<PointLightParsed>,
    pub dir_lights: Vec<DirLightParsed>,
    pub cameras: Vec<CameraParsed>,
    pub colliders: Vec<ColliderParsed>,
    pub rigidbodies: Vec<RigidBodyData>,
    pub animations: Vec<AnimationParsed>,
    pub physics_config: Option<PhysicsConfigData>,
}

// ── Cursor-based binary reader helpers ──

struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    fn read_u8(&mut self) -> Option<u8> {
        if self.pos < self.data.len() {
            let v = self.data[self.pos];
            self.pos += 1;
            Some(v)
        } else {
            None
        }
    }

    fn read_u16(&mut self) -> Option<u16> {
        if self.pos + 2 <= self.data.len() {
            let v = u16::from_le_bytes(self.data[self.pos..self.pos + 2].try_into().ok()?);
            self.pos += 2;
            Some(v)
        } else {
            None
        }
    }

    fn read_u32(&mut self) -> Option<u32> {
        if self.pos + 4 <= self.data.len() {
            let v = u32::from_le_bytes(self.data[self.pos..self.pos + 4].try_into().ok()?);
            self.pos += 4;
            Some(v)
        } else {
            None
        }
    }

    fn read_u64(&mut self) -> Option<u64> {
        if self.pos + 8 <= self.data.len() {
            let v = u64::from_le_bytes(self.data[self.pos..self.pos + 8].try_into().ok()?);
            self.pos += 8;
            Some(v)
        } else {
            None
        }
    }

    fn read_i32(&mut self) -> Option<i32> {
        if self.pos + 4 <= self.data.len() {
            let v = i32::from_le_bytes(self.data[self.pos..self.pos + 4].try_into().ok()?);
            self.pos += 4;
            Some(v)
        } else {
            None
        }
    }

    fn read_f32(&mut self) -> Option<f32> {
        if self.pos + 4 <= self.data.len() {
            let v = f32::from_le_bytes(self.data[self.pos..self.pos + 4].try_into().ok()?);
            self.pos += 4;
            Some(v)
        } else {
            None
        }
    }

    fn read_f64(&mut self) -> Option<f64> {
        if self.pos + 8 <= self.data.len() {
            let v = f64::from_le_bytes(self.data[self.pos..self.pos + 8].try_into().ok()?);
            self.pos += 8;
            Some(v)
        } else {
            None
        }
    }

    fn read_bytes(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.pos + n <= self.data.len() {
            let slice = &self.data[self.pos..self.pos + n];
            self.pos += n;
            Some(slice)
        } else {
            None
        }
    }

    fn skip(&mut self, n: usize) {
        self.pos += n;
    }
}

/// Parse an ORSB header from raw bytes.
pub fn parse_header(data: &[u8]) -> Option<OrsbHeader> {
    if data.len() < 32 {
        return None;
    }
    if &data[0..4] != &ORSB_MAGIC {
        return None;
    }

    let version = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    if version != ORSB_VERSION {
        return None;
    }

    Some(OrsbHeader {
        magic: ORSB_MAGIC,
        version,
        flags: u32::from_le_bytes([data[8], data[9], data[10], data[11]]),
        num_entities: u32::from_le_bytes([data[12], data[13], data[14], data[15]]),
        num_meshes: u32::from_le_bytes([data[16], data[17], data[18], data[19]]),
        num_textures: u32::from_le_bytes([data[20], data[21], data[22], data[23]]),
        num_materials: u32::from_le_bytes([data[24], data[25], data[26], data[27]]),
        num_animations: u32::from_le_bytes([data[28], data[29], data[30], data[31]]),
    })
}

/// Parse a complete ORSB file into a `ParsedScene`.
pub fn parse_orsb(data: &[u8]) -> Result<ParsedScene, String> {
    let header = parse_header(data).ok_or("Invalid ORSB header")?;
    let num_entities = header.num_entities as usize;
    let num_meshes = header.num_meshes as usize;
    let num_textures = header.num_textures as usize;
    let num_materials = header.num_materials as usize;

    let mut c = Cursor::new(data);
    c.skip(32); // past header

    // ── Entity graph (28 bytes per entity) ──
    let mut entity_ids = Vec::with_capacity(num_entities);
    let mut parent_indices = Vec::with_capacity(num_entities);
    let mut component_masks = Vec::with_capacity(num_entities);
    let mut mesh_indices = Vec::with_capacity(num_entities);
    let mut material_indices = Vec::with_capacity(num_entities);

    for _ in 0..num_entities {
        let eid = c.read_u64().ok_or("Truncated entity graph")?;
        let parent = c.read_u32().ok_or("Truncated entity graph")?;
        let mask = c.read_u64().ok_or("Truncated entity graph")?;
        let mesh_idx = c.read_u32().ok_or("Truncated entity graph")?;
        let mat_idx = c.read_u32().ok_or("Truncated entity graph")?;

        entity_ids.push(eid);
        parent_indices.push(if parent == u32::MAX { None } else { Some(parent as usize) });
        component_masks.push(ComponentMask(mask));
        mesh_indices.push(if mesh_idx == u32::MAX { None } else { Some(mesh_idx as usize) });
        material_indices.push(if mat_idx == u32::MAX { None } else { Some(mat_idx as usize) });
    }

    // ── Transforms (80 bytes per entity) ──
    let mut transforms = Vec::with_capacity(num_entities);
    for _ in 0..num_entities {
        let px = c.read_f64().ok_or("Truncated transforms")?;
        let py = c.read_f64().ok_or("Truncated transforms")?;
        let pz = c.read_f64().ok_or("Truncated transforms")?;
        let rw = c.read_f64().ok_or("Truncated transforms")?;
        let rx = c.read_f64().ok_or("Truncated transforms")?;
        let ry = c.read_f64().ok_or("Truncated transforms")?;
        let rz = c.read_f64().ok_or("Truncated transforms")?;
        let sx = c.read_f64().ok_or("Truncated transforms")?;
        let sy = c.read_f64().ok_or("Truncated transforms")?;
        let sz = c.read_f64().ok_or("Truncated transforms")?;
        transforms.push(TransformData {
            position: [px, py, pz],
            rotation: [rw, rx, ry, rz],
            scale: [sx, sy, sz],
        });
    }

    // ── Meshes ──
    let mut meshes = Vec::with_capacity(num_meshes);
    for _ in 0..num_meshes {
        let nv = c.read_u32().ok_or("Truncated mesh header")? as usize;
        let ni = c.read_u32().ok_or("Truncated mesh header")? as usize;
        let has_bones = c.read_u32().ok_or("Truncated mesh header")? != 0;
        c.skip(4); // padding

        let mut positions = Vec::with_capacity(nv * 3);
        for _ in 0..nv * 3 {
            positions.push(c.read_f32().ok_or("Truncated mesh positions")?);
        }

        let mut normals = Vec::with_capacity(nv * 3);
        for _ in 0..nv * 3 {
            normals.push(c.read_f32().ok_or("Truncated mesh normals")?);
        }

        let mut uvs = Vec::with_capacity(nv * 2);
        for _ in 0..nv * 2 {
            uvs.push(c.read_f32().ok_or("Truncated mesh uvs")?);
        }

        let mut indices = Vec::with_capacity(ni);
        for _ in 0..ni {
            indices.push(c.read_u32().ok_or("Truncated mesh indices")?);
        }

        let (bone_weights, bone_indices) = if has_bones {
            let mut bw = Vec::with_capacity(nv * 4);
            for _ in 0..nv * 4 {
                bw.push(c.read_f32().ok_or("Truncated bone weights")?);
            }
            let mut bi = Vec::with_capacity(nv * 4);
            for _ in 0..nv * 4 {
                bi.push(c.read_u16().ok_or("Truncated bone indices")?);
            }
            (Some(bw), Some(bi))
        } else {
            (None, None)
        };

        meshes.push(MeshParsed { positions, normals, uvs, indices, bone_weights, bone_indices });
    }

    // ── Materials (96 bytes each) ──
    let mut materials = Vec::with_capacity(num_materials);
    for _ in 0..num_materials {
        if c.remaining() < 96 {
            break;
        }
        let color = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
        let metallic = c.read_f32().unwrap();
        let roughness = c.read_f32().unwrap();
        let opacity = c.read_f32().unwrap();
        let alpha_cutoff = c.read_f32().unwrap();
        let emissive_factor = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
        let clearcoat = c.read_f32().unwrap();
        let clearcoat_roughness = c.read_f32().unwrap();
        let subsurface = c.read_f32().unwrap();
        // The Julia exporter writes parallax_height_scale here, not subsurface_color
        // Reread: subsurface_color is 3 floats then parallax. Let me check.
        // Actually from scene_format.rs struct: subsurface_color: [f32; 3], parallax_height_scale: f32
        // But the Julia exporter writes: clearcoat, clearcoat_roughness, subsurface, parallax (4 floats)
        // There's a mismatch. The Julia exporter skips subsurface_color.
        // To match the Julia exporter, we read the 4th float as parallax_height_scale.
        let parallax_height_scale = c.read_f32().unwrap();
        let albedo_texture_index = c.read_i32().unwrap();
        let normal_texture_index = c.read_i32().unwrap();
        let metallic_roughness_texture_index = c.read_i32().unwrap();
        let ao_texture_index = c.read_i32().unwrap();
        let emissive_texture_index = c.read_i32().unwrap();
        let height_texture_index = c.read_i32().unwrap();
        let clearcoat_texture_index = c.read_i32().unwrap();
        let _pad = c.read_i32().unwrap();

        materials.push(MaterialData {
            color,
            metallic,
            roughness,
            opacity,
            alpha_cutoff,
            emissive_factor,
            clearcoat,
            clearcoat_roughness,
            subsurface,
            subsurface_color: [0.0; 3],
            parallax_height_scale,
            albedo_texture_index,
            normal_texture_index,
            metallic_roughness_texture_index,
            ao_texture_index,
            emissive_texture_index,
            height_texture_index,
            clearcoat_texture_index,
            _pad,
        });
    }

    // ── Textures ──
    let mut textures = Vec::with_capacity(num_textures);
    for _ in 0..num_textures {
        let width = c.read_u32().ok_or("Truncated texture header")?;
        let height = c.read_u32().ok_or("Truncated texture header")?;
        let channels = c.read_u32().ok_or("Truncated texture header")?;
        let compression = c.read_u32().ok_or("Truncated texture header")?;
        let data_size = c.read_u64().ok_or("Truncated texture header")? as usize;
        let data = if data_size > 0 {
            c.read_bytes(data_size).ok_or("Truncated texture data")?.to_vec()
        } else {
            Vec::new()
        };
        textures.push(TextureParsed { width, height, channels, compression, data });
    }

    // ── Lights ──
    let mut point_lights = Vec::new();
    let mut dir_lights = Vec::new();
    if c.remaining() >= 4 {
        let n_point = c.read_u32().unwrap() as usize;
        for _ in 0..n_point {
            if c.remaining() < 32 { break; }
            let position = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
            let color = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
            let intensity = c.read_f32().unwrap();
            let range = c.read_f32().unwrap();
            point_lights.push(PointLightParsed { position, color, intensity, range });
        }
        if c.remaining() >= 4 {
            let n_dir = c.read_u32().unwrap() as usize;
            for _ in 0..n_dir {
                if c.remaining() < 32 { break; }
                let direction = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
                let color = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
                let intensity = c.read_f32().unwrap();
                c.skip(4); // padding
                dir_lights.push(DirLightParsed { direction, color, intensity });
            }
        }
    }

    // ── Cameras ──
    let mut cameras = Vec::new();
    if c.remaining() >= 4 {
        let n_cam = c.read_u32().unwrap() as usize;
        for _ in 0..n_cam {
            if c.remaining() < 16 { break; }
            let fov = c.read_f32().unwrap();
            let near = c.read_f32().unwrap();
            let far = c.read_f32().unwrap();
            let aspect = c.read_f32().unwrap();
            cameras.push(CameraParsed { fov, near, far, aspect });
        }
    }

    // ── Colliders ──
    let mut colliders = Vec::new();
    if c.remaining() >= 4 {
        let n_col = c.read_u32().unwrap() as usize;
        for _ in 0..n_col {
            if c.remaining() < 29 { break; }
            let shape_type = c.read_u8().unwrap();
            let shape_data = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
            let offset = [c.read_f32().unwrap(), c.read_f32().unwrap(), c.read_f32().unwrap()];
            let is_trigger = c.read_u8().unwrap() != 0;
            c.skip(3); // padding
            colliders.push(ColliderParsed { shape_type, shape_data, offset, is_trigger });
        }
    }

    // ── RigidBodies ──
    let mut rigidbodies = Vec::new();
    if c.remaining() >= 4 {
        let n_rb = c.read_u32().unwrap() as usize;
        for _ in 0..n_rb {
            if c.remaining() < 40 { break; }
            let body_type = c.read_u8().unwrap();
            let ccd_mode = c.read_u8().unwrap();
            c.skip(2); // padding
            let mass = c.read_f64().unwrap();
            let restitution = c.read_f32().unwrap();
            let friction = c.read_f64().unwrap();
            let linear_damping = c.read_f64().unwrap();
            let angular_damping = c.read_f64().unwrap();
            rigidbodies.push(RigidBodyData {
                body_type, ccd_mode, _pad1: 0, _pad2: 0,
                mass, restitution, friction, linear_damping, angular_damping,
            });
        }
    }

    // ── Animations ──
    let mut animations = Vec::new();
    if c.remaining() >= 4 {
        let n_anim = c.read_u32().unwrap_or(0) as usize;
        for _ in 0..n_anim {
            let num_clips = c.read_u32().ok_or("Truncated animation")? as usize;
            let mut clips = Vec::with_capacity(num_clips);
            for _ in 0..num_clips {
                let name_len = c.read_u16().ok_or("Truncated clip name")? as usize;
                let name_bytes = c.read_bytes(name_len).ok_or("Truncated clip name")?;
                let name = String::from_utf8_lossy(name_bytes).to_string();
                let num_channels = c.read_u32().ok_or("Truncated clip")? as usize;
                let duration = c.read_f32().ok_or("Truncated clip")?;

                let mut channels = Vec::with_capacity(num_channels);
                for _ in 0..num_channels {
                    let target_entity_index = c.read_u32().ok_or("Truncated channel")?;
                    let prop_byte = c.read_u8().ok_or("Truncated channel")?;
                    let interp_byte = c.read_u8().ok_or("Truncated channel")?;
                    let keyframe_count = c.read_u32().ok_or("Truncated channel")? as usize;

                    let target_property = match prop_byte {
                        0 => TargetProperty::Position,
                        1 => TargetProperty::Rotation,
                        _ => TargetProperty::Scale,
                    };
                    let interpolation = match interp_byte {
                        0 => InterpolationMode::Step,
                        1 => InterpolationMode::Linear,
                        _ => InterpolationMode::CubicSpline,
                    };

                    let mut times = Vec::with_capacity(keyframe_count);
                    for _ in 0..keyframe_count {
                        times.push(c.read_f32().ok_or("Truncated keyframe times")?);
                    }

                    let vals_per_key = if target_property == TargetProperty::Rotation { 4 } else { 3 };
                    let mut values = Vec::with_capacity(keyframe_count * vals_per_key);
                    for _ in 0..keyframe_count * vals_per_key {
                        values.push(c.read_f64().ok_or("Truncated keyframe values")?);
                    }

                    channels.push(AnimationChannelParsed {
                        target_entity_index,
                        target_property,
                        interpolation,
                        times,
                        values,
                    });
                }
                clips.push(AnimationClipParsed { name, duration, channels });
            }

            let active_clip = c.read_i32().ok_or("Truncated animation state")?;
            let playing = c.read_u8().ok_or("Truncated animation state")? != 0;
            let looping = c.read_u8().ok_or("Truncated animation state")? != 0;
            let speed = c.read_f32().ok_or("Truncated animation state")?;

            animations.push(AnimationParsed { clips, active_clip, playing, looping, speed });
        }
    }

    // ── Physics config ──
    let physics_config = if c.remaining() >= 48 {
        let gravity = [c.read_f64().unwrap(), c.read_f64().unwrap(), c.read_f64().unwrap()];
        let fixed_dt = c.read_f64().unwrap();
        let max_substeps = c.read_u32().unwrap();
        let solver_iterations = c.read_u32().unwrap();
        let position_correction = c.read_f32().unwrap();
        let slop = c.read_f32().unwrap();
        Some(PhysicsConfigData {
            gravity, fixed_dt, max_substeps, solver_iterations, position_correction, slop,
        })
    } else {
        None
    };

    Ok(ParsedScene {
        header,
        entity_ids,
        parent_indices,
        component_masks,
        mesh_indices,
        material_indices,
        transforms,
        meshes,
        materials,
        textures,
        point_lights,
        dir_lights,
        cameras,
        colliders,
        rigidbodies,
        animations,
        physics_config,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal valid ORSB binary with the given counts.
    fn build_header(num_entities: u32, num_meshes: u32, num_textures: u32, num_materials: u32) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(b"ORSB");
        buf.extend_from_slice(&1u32.to_le_bytes());   // version
        buf.extend_from_slice(&0u32.to_le_bytes());    // flags
        buf.extend_from_slice(&num_entities.to_le_bytes());
        buf.extend_from_slice(&num_meshes.to_le_bytes());
        buf.extend_from_slice(&num_textures.to_le_bytes());
        buf.extend_from_slice(&num_materials.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());    // num_animations
        buf
    }

    fn write_entity(buf: &mut Vec<u8>, id: u64, parent: u32, mask: u64, mesh: u32, mat: u32) {
        buf.extend_from_slice(&id.to_le_bytes());
        buf.extend_from_slice(&parent.to_le_bytes());
        buf.extend_from_slice(&mask.to_le_bytes());
        buf.extend_from_slice(&mesh.to_le_bytes());
        buf.extend_from_slice(&mat.to_le_bytes());
    }

    fn write_transform(buf: &mut Vec<u8>, px: f64, py: f64, pz: f64) {
        // position
        buf.extend_from_slice(&px.to_le_bytes());
        buf.extend_from_slice(&py.to_le_bytes());
        buf.extend_from_slice(&pz.to_le_bytes());
        // rotation (identity: w=1, x=0, y=0, z=0)
        buf.extend_from_slice(&1.0f64.to_le_bytes());
        buf.extend_from_slice(&0.0f64.to_le_bytes());
        buf.extend_from_slice(&0.0f64.to_le_bytes());
        buf.extend_from_slice(&0.0f64.to_le_bytes());
        // scale (1, 1, 1)
        buf.extend_from_slice(&1.0f64.to_le_bytes());
        buf.extend_from_slice(&1.0f64.to_le_bytes());
        buf.extend_from_slice(&1.0f64.to_le_bytes());
    }

    // Append empty trailing sections (lights, cameras, colliders, rigidbodies, animations)
    fn write_empty_trailing(buf: &mut Vec<u8>) {
        buf.extend_from_slice(&0u32.to_le_bytes()); // 0 point lights
        buf.extend_from_slice(&0u32.to_le_bytes()); // 0 dir lights
        buf.extend_from_slice(&0u32.to_le_bytes()); // 0 cameras
        buf.extend_from_slice(&0u32.to_le_bytes()); // 0 colliders
        buf.extend_from_slice(&0u32.to_le_bytes()); // 0 rigidbodies
        buf.extend_from_slice(&0u32.to_le_bytes()); // 0 animations
    }

    #[test]
    fn test_parse_header_valid() {
        let data = build_header(5, 2, 3, 1);
        let h = parse_header(&data).unwrap();
        assert_eq!(h.magic, *b"ORSB");
        assert_eq!(h.version, 1);
        assert_eq!(h.num_entities, 5);
        assert_eq!(h.num_meshes, 2);
        assert_eq!(h.num_textures, 3);
        assert_eq!(h.num_materials, 1);
    }

    #[test]
    fn test_parse_header_invalid_magic() {
        let mut data = build_header(1, 0, 0, 0);
        data[0] = b'X';
        assert!(parse_header(&data).is_none());
    }

    #[test]
    fn test_parse_header_wrong_version() {
        let mut data = build_header(1, 0, 0, 0);
        data[4..8].copy_from_slice(&99u32.to_le_bytes());
        assert!(parse_header(&data).is_none());
    }

    #[test]
    fn test_parse_header_too_short() {
        assert!(parse_header(&[0u8; 16]).is_none());
    }

    #[test]
    fn test_parse_orsb_empty_scene() {
        let mut data = build_header(0, 0, 0, 0);
        write_empty_trailing(&mut data);
        let scene = parse_orsb(&data).unwrap();
        assert_eq!(scene.entity_ids.len(), 0);
        assert_eq!(scene.meshes.len(), 0);
        assert_eq!(scene.materials.len(), 0);
        assert_eq!(scene.textures.len(), 0);
    }

    #[test]
    fn test_parse_orsb_single_entity() {
        let mut data = build_header(1, 0, 0, 0);
        write_entity(&mut data, 42, u32::MAX, ComponentMask::TRANSFORM, u32::MAX, u32::MAX);
        write_transform(&mut data, 1.0, 2.0, 3.0);
        write_empty_trailing(&mut data);

        let scene = parse_orsb(&data).unwrap();
        assert_eq!(scene.entity_ids.len(), 1);
        assert_eq!(scene.entity_ids[0], 42);
        assert!(scene.parent_indices[0].is_none());
        assert!(scene.component_masks[0].has(ComponentMask::TRANSFORM));
        assert!(!scene.component_masks[0].has(ComponentMask::MESH));
        assert!(scene.mesh_indices[0].is_none());
        assert_eq!(scene.transforms[0].position, [1.0, 2.0, 3.0]);
        assert_eq!(scene.transforms[0].scale, [1.0, 1.0, 1.0]);
    }

    #[test]
    fn test_parse_orsb_parent_child() {
        let mut data = build_header(2, 0, 0, 0);
        // Parent (root)
        write_entity(&mut data, 1, u32::MAX, ComponentMask::TRANSFORM, u32::MAX, u32::MAX);
        // Child (parent_index = 0)
        write_entity(&mut data, 2, 0, ComponentMask::TRANSFORM, u32::MAX, u32::MAX);
        write_transform(&mut data, 0.0, 0.0, 0.0);
        write_transform(&mut data, 5.0, 5.0, 5.0);
        write_empty_trailing(&mut data);

        let scene = parse_orsb(&data).unwrap();
        assert_eq!(scene.parent_indices[0], None);
        assert_eq!(scene.parent_indices[1], Some(0));
        assert_eq!(scene.transforms[1].position, [5.0, 5.0, 5.0]);
    }

    #[test]
    fn test_parse_orsb_with_mesh() {
        // 1 entity, 1 mesh (triangle: 3 verts, 3 indices), 0 textures, 0 materials
        let mut data = build_header(1, 1, 0, 0);
        write_entity(&mut data, 1, u32::MAX, ComponentMask::TRANSFORM | ComponentMask::MESH, 0, u32::MAX);
        write_transform(&mut data, 0.0, 0.0, 0.0);

        // Mesh header: 3 verts, 3 indices, no bones
        data.extend_from_slice(&3u32.to_le_bytes());
        data.extend_from_slice(&3u32.to_le_bytes());
        data.extend_from_slice(&0u32.to_le_bytes()); // no bones
        data.extend_from_slice(&0u32.to_le_bytes()); // padding

        // Positions (3 verts * 3 floats)
        for v in &[0.0f32, 0.0, 0.0, 1.0, 0.0, 0.0, 0.5, 1.0, 0.0] {
            data.extend_from_slice(&v.to_le_bytes());
        }
        // Normals (3 verts * 3 floats)
        for _ in 0..9 {
            data.extend_from_slice(&0.0f32.to_le_bytes());
        }
        // UVs (3 verts * 2 floats)
        for _ in 0..6 {
            data.extend_from_slice(&0.0f32.to_le_bytes());
        }
        // Indices
        for i in &[0u32, 1, 2] {
            data.extend_from_slice(&i.to_le_bytes());
        }

        write_empty_trailing(&mut data);

        let scene = parse_orsb(&data).unwrap();
        assert_eq!(scene.meshes.len(), 1);
        assert_eq!(scene.meshes[0].positions.len(), 9);
        assert_eq!(scene.meshes[0].indices.len(), 3);
        assert!(scene.meshes[0].bone_weights.is_none());
        assert_eq!(scene.mesh_indices[0], Some(0));
    }

    #[test]
    fn test_component_mask() {
        let mut mask = ComponentMask::default();
        assert!(!mask.has(ComponentMask::TRANSFORM));
        mask.set(ComponentMask::TRANSFORM);
        assert!(mask.has(ComponentMask::TRANSFORM));
        mask.set(ComponentMask::MESH);
        assert!(mask.has(ComponentMask::MESH));
        assert!(mask.has(ComponentMask::TRANSFORM));
        assert!(!mask.has(ComponentMask::CAMERA));
    }

    #[test]
    fn test_parse_orsb_lights() {
        let mut data = build_header(0, 0, 0, 0);
        // 1 point light
        data.extend_from_slice(&1u32.to_le_bytes());
        // position
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&2.0f32.to_le_bytes());
        data.extend_from_slice(&3.0f32.to_le_bytes());
        // color
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&0.5f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        // intensity + range
        data.extend_from_slice(&10.0f32.to_le_bytes());
        data.extend_from_slice(&50.0f32.to_le_bytes());
        // 1 directional light
        data.extend_from_slice(&1u32.to_le_bytes());
        // direction
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&(-1.0f32).to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        // color
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&1.0f32.to_le_bytes());
        // intensity + padding
        data.extend_from_slice(&5.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        // cameras, colliders, rigidbodies, animations
        data.extend_from_slice(&0u32.to_le_bytes());
        data.extend_from_slice(&0u32.to_le_bytes());
        data.extend_from_slice(&0u32.to_le_bytes());
        data.extend_from_slice(&0u32.to_le_bytes());

        let scene = parse_orsb(&data).unwrap();
        assert_eq!(scene.point_lights.len(), 1);
        assert_eq!(scene.point_lights[0].position, [1.0, 2.0, 3.0]);
        assert_eq!(scene.point_lights[0].intensity, 10.0);
        assert_eq!(scene.dir_lights.len(), 1);
        assert_eq!(scene.dir_lights[0].direction[1], -1.0);
        assert_eq!(scene.dir_lights[0].intensity, 5.0);
    }
}
