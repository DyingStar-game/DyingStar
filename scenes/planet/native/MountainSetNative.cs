using System.Collections.Generic;
using Godot;

/// <summary>
/// The mountain features of one pack tile (or of a chunk frame), summed in a
/// single call per sample — MountainRelief.offset in C#. Built once (Add*),
/// read-only afterwards, shared by the chunk workers.
/// </summary>
public partial class MountainSetNative : RefCounted
{
    private readonly List<MountainZoneNative> _zones = new();
    private readonly List<MountainRidgeNative> _ridges = new();
    private bool _needLonLat;

    public void AddZone(GodotObject zone)
    {
        var z = zone as MountainZoneNative;
        if (z == null) return;
        _zones.Add(z);
        if (!z.IsFull()) _needLonLat = true;
    }

    public void AddRidge(GodotObject ridge)
    {
        var r = ridge as MountainRidgeNative;
        if (r == null) return;
        _ridges.Add(r);
        _needLonLat = true;
    }

    public bool IsEmpty() => _zones.Count == 0 && _ridges.Count == 0;
    public int ZoneCount() => _zones.Count;
    public int RidgeCount() => _ridges.Count;

    /// <summary>Total offset (m) at dir for a grid of pitch effSpacing (> 0).</summary>
    public double Offset(Vector3 dir, double radius, double effSpacing)
    {
        double dx = dir.X, dy = dir.Y, dz = dir.Z;
        double lon = double.NaN, lat = double.NaN;
        if (_needLonLat)
            MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
        double total = 0.0;
        for (int i = 0; i < _zones.Count; i++)
            total += _zones[i].OffsetD(dx, dy, dz, radius, effSpacing, lon, lat);
        for (int i = 0; i < _ridges.Count; i++)
            total += _ridges[i].HeightD(dx, dy, dz, radius, effSpacing, lon, lat);
        return total;
    }
}
