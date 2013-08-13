var ecoapi_ver = "0.01";
var point_list;

function url_base()
{
    var base = "http://" + window.location.host + "/";
    console.log(base);
    if(base === "http:///")
    {
        base = 'http://127.0.0.1:8080/';
        console.log(base);
    }
    return base;
}
function url_base_map()
{
    var base = 'http://' + window.location.hostname + ':8081/tiles/{z}/{x}/{y}.png';
    console.log(base);
    if(base === "http://:8081/tiles/{z}/{x}/{y}.png")
    {
        base = 'http://127.0.0.1:8081/tiles/{z}/{x}/{y}.png';
        console.log(base);
    }
    return base;
}
function rpc_gate(jsonObjects, on_success, on_error)
{
    var base_url = url_base();
    var request = {
        type: 'POST',
        dataType: 'json',
        async: true,
        timeout: 20000,
        contentType: 'application/json',
        url: base_url + 'rpc-json/rpc_gate.pl',
        data: JSON.stringify(jsonObjects)+";",
    };
    if(typeof on_success !== 'undefined')
    {
        request['success'] = on_success;
    }
    if(typeof on_error !== 'undefined')
    {
        request['error'] = on_error;
    }
    console.log(jsonObjects);
    $.ajax(request);
}

var pl_lock = 0;
var pl_status = '';
var pl_list;
var pl_current;
var pl_update_func;

function pl_ok(response)
{
    pl_lock = 0;
    if(response)
    {
        pl_status = 'ok';

        console.log(response);
        if("result" in response)
        {
            if("rows" in response["result"])
            {
                pl_list = response["result"]["rows"];
            }
            if("current_StationID" in response["result"])
            {
                pl_current = response["result"]["current_StationID"];
            }
        }
    }else{
        pl_status = 'error';
    }
    if(typeof pl_update_func !== 'undefined')
    {
        pl_update_func();
    }
}
function pl_err(response)
{
    pl_lock = 0;
    pl_status = 'error';
    if(typeof pl_update_func !== 'undefined')
    {
        pl_update_func();
    }
}
function get_point_list()
{
    if(pl_lock == 0)
    {
        pl_lock = 1;
        var jsonObjects = {"method":"status_info", "data":{}};
        jsonObjects["data"]["list_points"] = 1;
        jsonObjects["data"]["get_current_point"] = 1;
        rpc_gate(jsonObjects, pl_ok, pl_err);
    }
}

var gps_lock = 0;
var gps_status = '';
var gpslocation = [];
var gps_update_func;
function gps_ok(response)
{
    gps_lock = 0;
    if(response)
    {
        gps_status = 'ok';

        console.log(response);
        if("result" in response)
        {
            if("gps" in response["result"])
            {
                if("la" in response["result"]["gps"])
                {
                    gpslocation["la"] = response["result"]["gps"]["la"];
                }
                if("lo" in response["result"]["gps"])
                {
                    gpslocation["lo"] = response["result"]["gps"]["lo"];
                }
            }else{
                gps_status = 'error';
            }
        }
    }else{
        gps_status = 'error';
    }
    if(typeof gps_update_func !== 'undefined')
    {
        gps_update_func();
    }
}
function gps_err()
{
    gps_lock = 0;
    gps_status = 'error';
    if(typeof gps_update_func !== 'undefined')
    {
        gps_update_func();
    }
}
function gps_getlocation()
{
    if(gps_lock == 0)
    {
        gps_lock = 1;
        var jsonObjects = {"method":"status_info", "data":{}};
        jsonObjects["data"]["gps"] = 1;
        rpc_gate(jsonObjects, gps_ok, gps_err);
    }
}
var pc_lock = 0;
var pc_status = '';
var pc_update_func;

function pc_ok(response)
{
    pc_lock = 0;
    if(response)
    {
        pc_status = 'ok';

        console.log(response);
        if("result" in response)
        {
            if("current_StationID" in response["result"])
            {
                pl_current = response["result"]["current_StationID"];
            }
        }
    }else{
        pc_status = 'error';
    }
    if(typeof pc_update_func !== 'undefined')
    {
        pc_update_func();
    }
}
function pc_err(response)
{
    pc_lock = 0;
    pc_status = 'error';
    if(typeof pc_update_func !== 'undefined')
    {
        pc_update_func();
    }
}
function get_point_current()
{
    if(pc_lock == 0)
    {
        pc_lock = 1;
        var jsonObjects = {"method":"status_info", "data":{}};
        jsonObjects["data"]["get_current_point"] = 1;
        rpc_gate(jsonObjects, pc_ok, pc_err);
    }
}
function fix_table(w,h)
{
    var arr = $(this).find(".datagrid-htable");
    if(arr.length > 0)
    {
        if(w == 'auto')
        {
            var real_width = $(arr[1]).prop('clientWidth');
            console.log('fix width to' + real_width);
            var list = $.map(this.find("*"), function (v) { if($(v).attr('id')){ return v;}});
            if(list.length == 1)
            {
                $(list[0]).datagrid({width: real_width});
            }
        }
    }
}
function setup_table(tag, columns, data)
{
    $("#"+tag).datagrid({columns: columns,
                         onResize: fix_table});
}
