# Skinning system: compute bone matrices each frame

const MAX_BONES = 128

"""
    update_skinned_meshes!()

For each entity with a SkinnedMeshComponent, compute the final bone matrices:
    bone_matrices[i] = inverse(mesh_world) * bone_world * inverse_bind_matrix

Call this once per frame before rendering.
"""
function update_skinned_meshes!()
    iterate_components(SkinnedMeshComponent) do eid, skin
        mesh_world = get_world_transform(eid)
        inv_mesh_world = inv(mesh_world)

        num_bones = length(skin.bone_entities)
        num_bones == 0 && return

        # Resize bone_matrices if needed
        if length(skin.bone_matrices) != num_bones
            resize!(skin.bone_matrices, num_bones)
            for i in 1:num_bones
                skin.bone_matrices[i] = Mat4f(I)
            end
        end

        for i in 1:min(num_bones, MAX_BONES)
            bone_eid = skin.bone_entities[i]
            bone_comp = get_component(bone_eid, BoneComponent)

            if bone_comp !== nothing
                bone_world = get_world_transform(bone_eid)
                skin.bone_matrices[i] = Mat4f(inv_mesh_world * bone_world) * bone_comp.inverse_bind_matrix
            else
                skin.bone_matrices[i] = Mat4f(I)
            end
        end
    end
end
