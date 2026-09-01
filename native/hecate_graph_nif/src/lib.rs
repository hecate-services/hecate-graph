//! CozoDB NIF for hecate-graph.
//!
//! Embeds CozoDB — a transactional, relational-graph-vector database that
//! uses Datalog for queries — as an Erlang NIF via Rustler.
//!
//! The NIF owns a single CozoDB instance (`cozo::DbInstance`, the crate's
//! own storage-agnostic facade) backed by RocksDB on local disk. All
//! queries are Datalog strings, so the Erlang side never needs to know the
//! internal storage format.
//!
//! ## NIF functions
//!
//! - `open(Path)` — open or create a CozoDB instance at `Path`
//! - `run_query(Resource, Query, Params)` — run a Datalog query with params
//! - `run_script(Resource, Script)` — run a multi-statement Datalog script
//! - `close(Resource)` — drop the underlying database handle, releasing
//!   RocksDB's on-disk lock so the same path can be reopened
//! - `backup(Resource, Path)` / `restore(Resource, Path)` — SQLite-file
//!   backup/restore, via cozo's `backup_db`/`restore_backup`
//!
//! Every query runs through `DbInstance::run_script_fold_err/3`, which is
//! documented panic-safe: any query error is folded into the returned JSON
//! rather than unwinding, which matters here since a panic inside a NIF
//! call would crash the whole BEAM VM, not just this request.
//!
//! ## Fallback
//!
//! If the NIF is not loaded (no Rust toolchain at build time), the Erlang
//! wrapper module returns `{error, nif_not_loaded}`. There is no pure-Erlang
//! fallback for a graph database.

use cozo::{DataValue, DbInstance, ScriptMutability};
use rustler::{Atom, Binary, Encoder, Env, MapIterator, NifResult, ResourceArc, Term};
use std::collections::BTreeMap;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nif_not_loaded,
        database_closed,
    }
}

/// CozoDB instance wrapped in a Mutex for thread-safe access from NIFs.
///
/// `Option` so `close/1` can `.take()` it, dropping the handle immediately
/// (releasing RocksDB's LOCK file) instead of waiting for the ResourceArc
/// to be garbage collected on the Erlang side.
struct CozoDb(Mutex<Option<DbInstance>>);

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(CozoDb, env);
    true
}

/// Open or create a CozoDB instance with RocksDB storage at the given path.
#[rustler::nif]
fn open(env: Env, path: String) -> NifResult<Term> {
    let db = DbInstance::new("rocksdb", &path, "")
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo open failed: {}", e))))?;
    let resource = ResourceArc::new(CozoDb(Mutex::new(Some(db))));
    Ok((atoms::ok(), resource).encode(env))
}

/// Run a single Datalog query with optional parameters.
///
/// `Params` is a map of variable name -> value bindings.
/// Returns `{ok, #{headers => [...], rows => [...]}}` on success, or
/// `{error, Message}` when cozo reports a query error.
#[rustler::nif]
fn run_query<'a>(env: Env<'a>, resource: ResourceArc<CozoDb>, query: String, params: Term<'a>) -> NifResult<Term<'a>> {
    with_db(env, &resource, |db| {
        let params_map = term_to_params(params)?;
        let result = db.run_script_fold_err(&query, params_map, ScriptMutability::Mutable);
        Ok(query_result_to_term(env, result))
    })
}

/// Run a multi-statement Datalog script (no parameters).
#[rustler::nif]
fn run_script(env: Env, resource: ResourceArc<CozoDb>, script: String) -> NifResult<Term> {
    with_db(env, &resource, |db| {
        let result = db.run_script_fold_err(&script, BTreeMap::new(), ScriptMutability::Mutable);
        Ok(query_result_to_term(env, result))
    })
}

/// Translate cozo's `run_script_fold_err` JSON envelope
/// (`{"ok": bool, "headers": [...], "rows": [...], "took": f64}` on
/// success, `{"ok": false, "display": "...", ...}` on a query error — per
/// `cozo-core/src/lib.rs`'s own `run_script_fold_err`/`format_error_as_json`)
/// into the plain `{ok, #{headers, rows}} | {error, Message}` contract every
/// Erlang caller in this codebase expects.
fn query_result_to_term<'a>(env: Env<'a>, mut result: serde_json::Value) -> Term<'a> {
    let succeeded = result.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
    if succeeded {
        if let Some(map) = result.as_object_mut() {
            map.remove("ok");
            map.remove("took");
        }
        (atoms::ok(), json_to_term(env, &result)).encode(env)
    } else {
        let message = result
            .get("display")
            .or_else(|| result.get("message"))
            .and_then(|v| v.as_str())
            .unwrap_or("cozo query failed")
            .to_string();
        (atoms::error(), message).encode(env)
    }
}

/// Close the database: drop the handle now rather than at GC time, so the
/// same path can be reopened immediately (RocksDB holds an exclusive lock
/// file for as long as any handle is alive).
#[rustler::nif]
fn close(env: Env, resource: ResourceArc<CozoDb>) -> NifResult<Term> {
    let mut guard = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;
    *guard = None;
    Ok(atoms::ok().encode(env))
}

/// Backup the database to a SQLite file.
#[rustler::nif]
fn backup(env: Env, resource: ResourceArc<CozoDb>, path: String) -> NifResult<Term> {
    with_db(env, &resource, |db| {
        db.backup_db(&path)
            .map_err(|e| rustler::Error::Term(Box::new(format!("cozo backup failed: {}", e))))?;
        Ok(atoms::ok().encode(env))
    })
}

/// Restore the database from a SQLite file.
#[rustler::nif]
fn restore(env: Env, resource: ResourceArc<CozoDb>, path: String) -> NifResult<Term> {
    with_db(env, &resource, |db| {
        db.restore_backup(&path)
            .map_err(|e| rustler::Error::Term(Box::new(format!("cozo restore failed: {}", e))))?;
        Ok(atoms::ok().encode(env))
    })
}

/// Lock the resource and run `f` against the open `DbInstance`, or return
/// `{error, database_closed}` if `close/1` already dropped it.
fn with_db<'a, F>(env: Env<'a>, resource: &ResourceArc<CozoDb>, f: F) -> NifResult<Term<'a>>
where
    F: FnOnce(&DbInstance) -> NifResult<Term<'a>>,
{
    let guard = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;
    match guard.as_ref() {
        Some(db) => f(db),
        None => Ok((atoms::error(), atoms::database_closed()).encode(env)),
    }
}

// ---------------------------------------------------------------------------
// Params: Erlang term -> BTreeMap<String, DataValue>
// ---------------------------------------------------------------------------

fn term_to_params(params: Term) -> NifResult<BTreeMap<String, DataValue>> {
    match term_to_json(params)? {
        serde_json::Value::Object(obj) => Ok(obj
            .into_iter()
            .map(|(k, v)| (k, DataValue::from(v)))
            .collect()),
        serde_json::Value::Null => Ok(BTreeMap::new()),
        _ => Err(rustler::Error::Term(Box::new("params must be a map"))),
    }
}

// ---------------------------------------------------------------------------
// JSON <-> Erlang term conversion
// ---------------------------------------------------------------------------

fn term_to_json(term: Term) -> NifResult<serde_json::Value> {
    if term.is_atom() {
        let atom: Atom = term.decode()?;
        if atom == atoms::ok() { return Ok(serde_json::Value::Null); }
        return Ok(serde_json::Value::String(format!("{:?}", atom)));
    }
    if term.is_number() {
        if let Ok(i) = term.decode::<i64>() {
            return Ok(serde_json::Value::Number(i.into()));
        }
        if let Ok(f) = term.decode::<f64>() {
            if let Some(n) = serde_json::Number::from_f64(f) {
                return Ok(serde_json::Value::Number(n));
            }
        }
    }
    if term.is_binary() {
        let bin: Binary = term.decode()?;
        return Ok(serde_json::Value::String(
            String::from_utf8_lossy(bin.as_slice()).to_string()
        ));
    }
    if term.is_list() {
        let list: Vec<Term> = term.decode()?;
        let items: Result<Vec<serde_json::Value>, _> = list.iter()
            .map(|t| term_to_json(*t))
            .collect();
        return Ok(serde_json::Value::Array(items?));
    }
    if term.is_map() {
        let iter: MapIterator = term.decode()?;
        let mut map = serde_json::Map::new();
        for (k, v) in iter {
            let key = match term_to_json(k)? {
                serde_json::Value::String(s) => s,
                serde_json::Value::Number(n) => n.to_string(),
                _ => return Err(rustler::Error::Term(Box::new("map keys must be strings or numbers"))),
            };
            map.insert(key, term_to_json(v)?);
        }
        return Ok(serde_json::Value::Object(map));
    }
    Ok(serde_json::Value::Null)
}

fn json_to_term<'a>(env: Env<'a>, value: &serde_json::Value) -> Term<'a> {
    match value {
        serde_json::Value::Null => rustler::types::atom::nil().encode(env),
        serde_json::Value::Bool(b) => {
            if *b { rustler::types::atom::true_().encode(env) }
            else { rustler::types::atom::false_().encode(env) }
        }
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.encode(env)
            } else if let Some(f) = n.as_f64() {
                f.encode(env)
            } else {
                rustler::types::atom::nil().encode(env)
            }
        }
        serde_json::Value::String(s) => s.encode(env),
        serde_json::Value::Array(arr) => {
            let terms: Vec<Term> = arr.iter()
                .map(|v| json_to_term(env, v))
                .collect();
            terms.encode(env)
        }
        serde_json::Value::Object(obj) => {
            let pairs: Vec<(Term, Term)> = obj.iter()
                .map(|(k, v)| (k.encode(env), json_to_term(env, v)))
                .collect();
            Term::map_from_pairs(env, &pairs)
                .unwrap_or_else(|_| rustler::types::atom::nil().encode(env))
        }
    }
}

rustler::init!("hecate_graph_nif", load = load);
