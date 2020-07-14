#[derive(Debug)]
pub struct LibFoo;

#[test]
fn test_foo() {
    assert_eq!(util_crate::show(&LibFoo), "Libfoo");
}
