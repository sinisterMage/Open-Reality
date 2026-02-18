# Script system — runs ScriptComponent lifecycle callbacks

"""
    update_scripts!(dt::Float64)

Run script lifecycle callbacks for all entities with a ScriptComponent.
On the first tick, `on_start` is called once. Every tick, `on_update` is called.
A snapshot of entities is taken before iteration to tolerate mid-tick mutations.
"""
function update_scripts!(dt::Float64)
    entities = entities_with_component(ScriptComponent)
    isempty(entities) && return

    for eid in entities
        comp = get_component(eid, ScriptComponent)
        comp === nothing && continue

        if !comp._started
            if comp.on_start !== nothing
                try
                    comp.on_start(eid)
                catch e
                    @warn "ScriptComponent on_start error" exception=e
                end
            end
            comp._started = true
        end

        if comp.on_update !== nothing
            try
                comp.on_update(eid, dt)
            catch e
                @warn "ScriptComponent on_update error" exception=e
            end
        end
    end
end
