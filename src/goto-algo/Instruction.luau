--!strict

type instruction = {
    read mark: (self: instruction, marked: unknown, ...unknown) -> (),
    read hit: (self: instruction, mark: unknown) -> (boolean, ...any),
    read goto: (self: instruction, mark: unknown, ...any) -> ()
}

const private = {}
const class : instruction = table.freeze {

    --[=[
        Создать в пространстве точку-снимок состояния. В этом пространстве функция из которой
        было оно создано будет сохранена как снапшот, вместе с переданными в нее аргументами

        При `instruction.goto()` запустит именно это пространство с теми же сохраненными
        аргументами из снапшота, а также передаст аргументы из `goto` в `hit`
    ]=]
    mark = function (self: instruction, marked: unknown, ...: unknown) : ()
       private.get_marks(coroutine.running())[tostring(marked)] = private.get_stack_function(2, ...) 
    end,

    --[=[
        Проверка, было ли в данную точку в пространстве попадание извне
        Доступно только функции где была объявлена `instruction.mark()`, иначе `false`
    ]=]
    hit = function (self: instruction, mark: unknown) : (boolean, ...any)
        const marks = private.get_marks(coroutine.running())
        const marked = marks[mark]
        if not marked then return false end


    end,

    --[=[
        Перенестись к указанной точке в пространстве, снова войти в функцию
        и восстановить исполнение с того момента

        Аргументы могут быть любые, `instruction.hit()` вернет их
    ]=]
    goto = function (self: instruction, mark: unknown, ...: any) : ()
        const run = coroutine.running()
        const root = private.get_root(run)
        const marked = assert(private.get_marks(run)[mark], "mark does not exists for that corroutine")
        const child = coroutine.create(marked.func)

        marked.hit = true
        marked.transfer = table.freeze {...}

        table.insert(root, child)
        coroutine.resume(child, unpack(marked.basic))
        coroutine.close(run)
    end
}

do
    type coroutine = thread
    type func = (...any) -> ...any | (...any) -> ()
    type mark = unknown

    type marked = {
        read func: func,
        read args: number,
        read var: boolean,
        read basic: {unknown},
        
        hit: boolean,
        transfer: {unknown}
    }

    type blank<T = {}> = { [coroutine]: T }
    type marks = { [mark]: marked? }
    type root = { coroutine }

    private.meta = table.freeze {__mode = "ks"}
    private.marks = setmetatable({} :: blank<marks>, private.meta)
    private.root = setmetatable({} :: blank<root>, private.meta)
    private.transfer_default = table.freeze {} :: {unknown}
    private.alive = {} :: {coroutine}

    private.get_stack_function = function (stack_position: number, ...: unknown) : marked
        const func: func, capacity: number, var: boolean = debug.info(stack_position, "fa")
        const basic: {unknown} = table.freeze {...}


        assert(type(func) == "function", "cannot get current function from coroutine stack")
        assert(type(capacity) == "number", "cannot get argument information about marked function")
        assert(type(var) == "boolean", "cannot get variadic information about marked function")

        const result: marked = {
            func = func,
            args = capacity,
            var = var,
            basic = basic,
            transfer = private.transfer_default,
            hit = false
        }

        return result
    end

    private.get_root = function (of: coroutine) : root
        local root: root = private.root[of] :: any
        if not root then
            root = {} 
            private.root[of] = root
        end

        return root
    end

    private.get_marks = function (of: coroutine) : marks
        local marks: marks = private.marks[of] :: any
        if not marks then
            marks = {}
            private.marks[of] = marks
        end

        return marks
    end
end

return class