/*
    Every quarantined record must have at least one rejection reason.
    An empty rejection_reasons array means the quarantine logic has a bug.
*/

select
    reading_id,
    device_id,
    rejection_reasons
from {{ ref('int_quarantined_readings') }}
where array_size(rejection_reasons) = 0
