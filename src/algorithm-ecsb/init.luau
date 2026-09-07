--!strict
--!native
--!optimize 2

const ArrayBuffer = require("./ArrayBuffer")

type ECSB = buffer
type EID = number
type ETID = string|number
type tvalue = vector|number|boolean
type ttval = "vector" | "number" | "boolean"

export type Library = {
    read create: (max: number?) -> World,
}

export type World = {
    read etype: {[ETID]: ECSB},
    read eids: ECSB,

    read is_eid_exist: (self: World, eid: EID) -> boolean,

    read insert: (self: World) -> EID,
    read remove: (self: World, eid: EID?) -> boolean,

    read new_etype: (self: World, etid: ETID, tvalue: ttval) -> (),
    read get_etype: (self: World, etid: ETID, eid: EID) -> tvalue?,
    read set_etype: (self: World, etid: ETID, eid: EID, tvalue: tvalue) -> boolean,

    read intersect: (self: World, ...ETID) -> {EID},
    read union: (self: World, ...ETID) -> {EID},
    read negation: (self: World, ...ETID) -> {EID},
}

const LIBRARY_DEFAULT_MAX = 1024 ^ 2
const LIBRARY_DEFAULT_EID: "boolean" = "boolean"

const class : World = table.freeze {
    etype = {},
    eids = ArrayBuffer.create(LIBRARY_DEFAULT_EID, 10),

    insert = function (self: World) : EID
        return ArrayBuffer.put(self.eids, true)
    end,

    remove = function (self: World, eid: EID?) : boolean
        eid = eid or ArrayBuffer.next(self.eids, nil, true)
        if not eid then return false end

        const is = self:is_eid_exist(eid)
        if not is then return false end

        ArrayBuffer.write(self.eids, eid, nil)
        for _, v in self.etype do
            ArrayBuffer.write(v, eid, nil)
        end

        return true
    end,

    new_etype = function (self: World, etid: ETID, ttval: ttval) : ()
        assert(not self.etype[etid], "ETID already used, try another ETID name")
        self.etype[etid] = ArrayBuffer.create(ttval, ArrayBuffer.max(self.eids))
    end,

    get_etype = function (self: World, etid: ETID, eid: EID) : tvalue?
        return ArrayBuffer.read(self.etype[etid], eid) :: any
    end,

    is_eid_exist = function (self: World, eid: EID): boolean
        return ArrayBuffer.exist(self.eids, eid)
    end,

    set_etype = function (self: World, etid: ETID, eid: EID, tvalue: tvalue) : boolean
        const is = ArrayBuffer.exist(self.eids, eid)
        if not is then return false end

        ArrayBuffer.write(self.etype[etid], eid, tvalue)
        return true
    end,

    intersect = function(self: World, ...: ETID): {EID}
        const result: {EID} = table.create(ArrayBuffer.count(self.eids), -1)
        const types = table.freeze { ... }

        local eid = ArrayBuffer.next(self.eids)

        while eid do
            local valid = true

            for i = 1, #types do
                const etype = self.etype[types[i]]

                if not etype or ArrayBuffer.read(etype, eid) == nil then
                    valid = false
                    break
                end
            end

            if valid then
                result[#result + 1] = eid
            end

            eid = ArrayBuffer.next(self.eids, eid)
        end

        return result
    end,

    union = function(self: World, ...: ETID): {EID}
        const result: {EID} = {}
        const types = table.freeze { ... }

        for eid, _ in ArrayBuffer.iter(self.eids) do
            for i = 1, #types do
                const etype = self.etype[types[i]]

                if etype and ArrayBuffer.exist(etype, eid) then
                    result[#result + 1] = eid
                    break
                end
            end
        end

        return result
    end,

    negation = function(self: World, ...: ETID): {EID}
        const result: {EID} = {}
        const types = table.freeze { ... }

        for eid, _ in ArrayBuffer.iter(self.eids) do
            local valid = true

            for i = 1, #types do
                const etype = self.etype[types[i]]

                if etype and ArrayBuffer.exist(etype, eid) then
                    valid = false
                    break
                end
            end

            if valid then
                result[#result + 1] = eid
            end
        end

        return result
    end,
}

const library : Library = table.freeze {
    create = function (max: number?): World
        const new = table.clone(class) :: any

        new.etype = {}
        new.eids = ArrayBuffer.create(LIBRARY_DEFAULT_EID, max or LIBRARY_DEFAULT_MAX)

        return new
    end,
}


table.freeze(class)
table.freeze(library)

return library