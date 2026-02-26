use openreality_gpu_shared::scene_format::*;
use glam::{DVec3, DQuat, Mat4};

pub use openreality_gpu_shared::scene_format::{ScriptParsed, GameRefParsed};

/// A loaded entity with component data.
pub struct Entity {
    pub id: u64,
    pub parent_index: Option<usize>,
    pub transform: TransformState,
    pub world_transform: Mat4,
    pub mesh_index: Option<usize>,
    pub material_index: Option<usize>,
    pub mask: ComponentMask,
}

/// Runtime transform state (mutable, used for animation).
pub struct TransformState {
    pub position: DVec3,
    pub rotation: DQuat,
    pub scale: DVec3,
    pub dirty: bool,
}

/// Loaded mesh data (ready for GPU upload).
pub struct MeshData {
    pub positions: Vec<f32>,
    pub normals: Vec<f32>,
    pub uvs: Vec<f32>,
    pub indices: Vec<u32>,
    pub bone_weights: Option<Vec<f32>>,
    pub bone_indices: Option<Vec<u16>>,
}

/// Loaded material data.
pub struct MaterialInfo {
    pub color: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
    pub opacity: f32,
    pub alpha_cutoff: f32,
    pub emissive: [f32; 3],
    pub clearcoat: f32,
    pub subsurface: f32,
    pub texture_indices: [i32; 7],
}

/// Loaded texture data.
pub struct TextureData {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub compression: u32,
    pub data: Vec<u8>,
}

/// Animation clip for runtime playback.
pub struct AnimationClip {
    pub name: String,
    pub duration: f32,
    pub channels: Vec<AnimationChannel>,
}

pub struct AnimationChannel {
    pub target_entity_index: usize,
    pub target_property: TargetProperty,
    pub interpolation: InterpolationMode,
    pub times: Vec<f32>,
    pub values: Vec<f64>,
}

/// Animation playback state for an entity.
pub struct AnimationState {
    pub clips: Vec<AnimationClip>,
    pub active_clip: i32,
    pub current_time: f32,
    pub playing: bool,
    pub looping: bool,
    pub speed: f32,
}

/// Skeleton runtime data.
pub struct SkeletonData {
    /// Index of the entity this skeleton is attached to.
    pub entity_index: usize,
    /// Indices into the entity array for each bone.
    pub bone_entity_indices: Vec<usize>,
    /// Inverse bind matrices (one per bone).
    pub inverse_bind_matrices: Vec<Mat4>,
    /// Computed bone matrices (updated per frame by skinning system).
    pub bone_matrices: Vec<Mat4>,
}

/// Point light data for runtime.
pub struct PointLight {
    pub position: [f32; 3],
    pub color: [f32; 3],
    pub intensity: f32,
    pub range: f32,
}

/// Directional light data for runtime.
pub struct DirLight {
    pub direction: [f32; 3],
    pub color: [f32; 3],
    pub intensity: f32,
}

/// Camera data for runtime.
pub struct Camera {
    pub fov: f32,
    pub near: f32,
    pub far: f32,
    pub aspect: f32,
}

/// Complete loaded scene.
pub struct LoadedScene {
    pub entities: Vec<Entity>,
    pub meshes: Vec<MeshData>,
    pub materials: Vec<MaterialInfo>,
    pub textures: Vec<TextureData>,
    pub animations: Vec<AnimationState>,
    pub skeletons: Vec<SkeletonData>,
    pub point_lights: Vec<PointLight>,
    pub dir_lights: Vec<DirLight>,
    pub cameras: Vec<Camera>,
    pub physics_config: Option<PhysicsConfigData>,
    pub scripts: Vec<ScriptParsed>,
    pub game_refs: Vec<GameRefParsed>,
}

impl LoadedScene {
    /// Parse an ORSB binary file into a LoadedScene.
    pub fn from_orsb(data: &[u8]) -> Result<Self, String> {
        let parsed = parse_orsb(data)?;

        // Build entities
        let num_entities = parsed.entity_ids.len();
        let mut entities = Vec::with_capacity(num_entities);
        for i in 0..num_entities {
            let t = &parsed.transforms[i];
            entities.push(Entity {
                id: parsed.entity_ids[i],
                parent_index: parsed.parent_indices[i],
                transform: TransformState {
                    position: DVec3::new(t.position[0], t.position[1], t.position[2]),
                    rotation: DQuat::from_xyzw(t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[0]),
                    scale: DVec3::new(t.scale[0], t.scale[1], t.scale[2]),
                    dirty: true,
                },
                world_transform: Mat4::IDENTITY,
                mesh_index: parsed.mesh_indices[i],
                material_index: parsed.material_indices[i],
                mask: parsed.component_masks[i],
            });
        }

        // Build meshes
        let meshes = parsed.meshes.into_iter().map(|m| MeshData {
            positions: m.positions,
            normals: m.normals,
            uvs: m.uvs,
            indices: m.indices,
            bone_weights: m.bone_weights,
            bone_indices: m.bone_indices,
        }).collect();

        // Build materials
        let materials = parsed.materials.into_iter().map(|m| MaterialInfo {
            color: m.color,
            metallic: m.metallic,
            roughness: m.roughness,
            opacity: m.opacity,
            alpha_cutoff: m.alpha_cutoff,
            emissive: [m.emissive_factor[0], m.emissive_factor[1], m.emissive_factor[2]],
            clearcoat: m.clearcoat,
            subsurface: m.subsurface,
            texture_indices: [
                m.albedo_texture_index,
                m.normal_texture_index,
                m.metallic_roughness_texture_index,
                m.ao_texture_index,
                m.emissive_texture_index,
                m.height_texture_index,
                m.clearcoat_texture_index,
            ],
        }).collect();

        // Build textures
        let textures = parsed.textures.into_iter().map(|t| TextureData {
            width: t.width,
            height: t.height,
            channels: t.channels,
            compression: t.compression,
            data: t.data,
        }).collect();

        // Build lights
        let point_lights = parsed.point_lights.into_iter().map(|l| PointLight {
            position: l.position,
            color: l.color,
            intensity: l.intensity,
            range: l.range,
        }).collect();

        let dir_lights = parsed.dir_lights.into_iter().map(|l| DirLight {
            direction: l.direction,
            color: l.color,
            intensity: l.intensity,
        }).collect();

        // Build cameras
        let cameras = parsed.cameras.into_iter().map(|c| Camera {
            fov: c.fov,
            near: c.near,
            far: c.far,
            aspect: c.aspect,
        }).collect();

        // Build animations
        let animations = parsed.animations.into_iter().map(|a| AnimationState {
            clips: a.clips.into_iter().map(|clip| AnimationClip {
                name: clip.name,
                duration: clip.duration,
                channels: clip.channels.into_iter().map(|ch| AnimationChannel {
                    target_entity_index: ch.target_entity_index as usize,
                    target_property: ch.target_property,
                    interpolation: ch.interpolation,
                    times: ch.times,
                    values: ch.values,
                }).collect(),
            }).collect(),
            active_clip: a.active_clip,
            current_time: 0.0,
            playing: a.playing,
            looping: a.looping,
            speed: a.speed,
        }).collect();

        Ok(LoadedScene {
            entities,
            meshes,
            materials,
            textures,
            animations,
            skeletons: parsed.skeletons.into_iter().enumerate().map(|(i, s)| SkeletonData {
                entity_index: i,
                bone_entity_indices: s.bones.iter().map(|b| b.entity_index as usize).collect(),
                inverse_bind_matrices: s.bones.iter().map(|b| {
                    Mat4::from_cols_array_2d(&b.inverse_bind_matrix)
                }).collect(),
                bone_matrices: vec![Mat4::IDENTITY; s.bones.len()],
            }).collect(),
            point_lights,
            dir_lights,
            cameras,
            physics_config: parsed.physics_config,
            scripts: parsed.scripts,
            game_refs: parsed.game_refs,
        })
    }

    pub fn num_entities(&self) -> usize {
        self.entities.len()
    }

    pub fn num_meshes(&self) -> usize {
        self.meshes.len()
    }

    pub fn num_textures(&self) -> usize {
        self.textures.len()
    }
}
